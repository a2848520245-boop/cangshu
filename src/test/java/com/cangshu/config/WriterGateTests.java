package com.cangshu.config;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertSame;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import ch.qos.logback.classic.Logger;
import ch.qos.logback.classic.spi.ILoggingEvent;
import ch.qos.logback.core.read.ListAppender;
import java.io.IOException;
import java.nio.channels.FileChannel;
import java.nio.channels.FileLock;
import java.nio.channels.OverlappingFileLockException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardOpenOption;
import java.sql.SQLException;
import java.util.ArrayList;
import java.util.List;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;
import org.slf4j.LoggerFactory;

/**
 * 单写者启动门定向测试（任务 29，DEC-T2）。
 *
 * <p><b>不连数据库</b>：DB 会话锁通过 {@link WriterGate.SessionLockAcquirer} 注入替身，覆盖
 * 「成功／被其它写者占用／连不上库」三条分支；数据根文件锁走真实实现（{@code @TempDir} 落盘），
 * 因此独占语义与释放语义是实测结论而不是断言。
 *
 * <p><b>实测口径</b>：门持有文件锁期间，同一 JVM 内另一条通道对同一文件 {@code tryLock}
 * 抛 {@link OverlappingFileLockException}（Windows 11 ＋ JDK 21 实测）；跨进程的互斥由
 * {@code scripts/verify-task29-single-writer.ps1} 用真实双进程取证。
 *
 * <p><b>登记表断言取差值</b>：JVM 级登记是静态的，同一 JVM 里可能有别的 Spring 上下文持有别人的门，
 * 故只断言「相对基线 +1／回到基线」，不假设全局条数。
 */
class WriterGateTests {

    private static final String DATABASE_URL = "jdbc:postgresql://127.0.0.1:5432/cangshu_task29_unit?currentSchema=cangshu_m1";

    @TempDir
    Path temporaryDirectory;

    private final List<WriterGate> gates = new ArrayList<>();

    @AfterEach
    void releaseEveryGate() {
        gates.forEach(WriterGate::release);
        gates.clear();
    }

    // ── 获取与独占 ──────────────────────────────────────────────────────────────────────────

    @Test
    void acquiresBothLocksExclusivelyAndLogsTheGateLine() throws IOException {
        FakeSessionLock sessionLock = new FakeSessionLock();
        CangshuProperties properties = properties("exclusive-root");
        Path lockFile = dataRoot(properties).resolve(WriterGate.LOCK_FILE_NAME);
        int baselineDatabase = WriterGate.registeredDatabaseSessions();
        int baselineRoots = WriterGate.registeredDataRootLocks();
        try (CapturedLog log = captureGateLog()) {
            WriterGate gate = gate(properties, sessionLock);
            gate.acquire();

            assertTrue(gate.holdsGate(), "两把锁都拿到后本实例应当持有门");
            assertEquals(1, sessionLock.acquisitions(), "DB 会话锁只应尝试一次");
            assertEquals(CangshuProperties.WRITER_LOCK_KEY, sessionLock.lastKey(), "锁键必须取自既有协议常量");
            assertEquals(20260919L, sessionLock.lastKey(), "锁键登记值不得漂移");
            assertEquals(1, sessionLock.openHandles(), "取得后 DB 会话锁句柄必须保持打开");
            assertTrue(Files.isRegularFile(lockFile), "数据根下应当出现协议锁文件：" + lockFile);
            assertEquals(baselineDatabase + 1, WriterGate.registeredDatabaseSessions());
            assertEquals(baselineRoots + 1, WriterGate.registeredDataRootLocks());

            // 独占语义实测：门持锁期间，同一 JVM 内另一条通道拿不到这把锁。
            try (FileChannel channel = FileChannel.open(lockFile, StandardOpenOption.WRITE)) {
                assertThrows(OverlappingFileLockException.class, channel::tryLock,
                        "门持有文件锁期间，第二个持有者必须拿不到锁");
            }

            assertTrue(log.contains(WriterGate.ACQUIRED_MARKER + "|reused=false|reusedDb=false|reusedDataRoot=false"),
                    "门获取成功必须留结构化日志：" + log.lines());
            assertTrue(log.contains("dbUrl=" + DATABASE_URL), "日志要带 DB 标识：" + log.lines());
            assertTrue(log.contains("lockFile=" + lockFile), "日志要带锁文件路径：" + log.lines());
            assertTrue(log.contains("writerLockKey=20260919"), "日志要带锁键：" + log.lines());
        }
    }

    @Test
    void secondAcquisitionInSameJvmReusesTheHeldGate() {
        FakeSessionLock sessionLock = new FakeSessionLock();
        CangshuProperties properties = properties("reuse-root");
        int baselineDatabase = WriterGate.registeredDatabaseSessions();
        int baselineRoots = WriterGate.registeredDataRootLocks();
        try (CapturedLog log = captureGateLog()) {
            WriterGate first = gate(properties, sessionLock);
            WriterGate second = gate(properties, sessionLock);

            first.acquire();
            second.acquire();   // 同一 JVM、同一 (DB URL, 数据根)：幂等复用，不重复真抢锁

            assertTrue(first.holdsGate() && second.holdsGate(), "同一进程内的第二个上下文必须复用已持有的门");
            assertEquals(1, sessionLock.acquisitions(), "复用不得再次调用 pg_try_advisory_lock");
            assertEquals(1, sessionLock.openHandles(), "复用不得新开第二条持锁连接");
            assertEquals(baselineDatabase + 1, WriterGate.registeredDatabaseSessions());
            assertEquals(baselineRoots + 1, WriterGate.registeredDataRootLocks());
            assertTrue(log.contains(WriterGate.ACQUIRED_MARKER + "|reused=true|reusedDb=true|reusedDataRoot=true"),
                    "复用要留 reused=true 的证据：" + log.lines());
        }
    }

    @Test
    void sameJvmDifferentDataRootSharesDatabaseSessionButTakesItsOwnFileLock() {
        FakeSessionLock sessionLock = new FakeSessionLock();
        CangshuProperties firstProperties = properties("root-a");
        CangshuProperties secondProperties = properties("root-b");
        int baselineRoots = WriterGate.registeredDataRootLocks();
        try (CapturedLog log = captureGateLog()) {
            WriterGate first = gate(firstProperties, sessionLock);
            WriterGate second = gate(secondProperties, sessionLock);

            first.acquire();
            second.acquire();

            assertTrue(first.holdsGate() && second.holdsGate(), "同 JVM 不同数据根各自持有自己的门");
            assertEquals(1, sessionLock.acquisitions(),
                    "同一库在同一 JVM 内只持有一条会话锁连接（PG 咨询锁按会话冲突，重复调用只会被自己拒绝）");
            assertEquals(baselineRoots + 2, WriterGate.registeredDataRootLocks(), "每个数据根各有一把文件锁");
            assertTrue(Files.isRegularFile(dataRoot(secondProperties).resolve(WriterGate.LOCK_FILE_NAME)),
                    "第二个数据根也要落自己的锁文件");
            assertTrue(log.contains("reusedDb=true|reusedDataRoot=false"),
                    "第二个数据根的 DB 会话锁复用、文件锁新取：" + log.lines());
        }
    }

    @Test
    void releaseAllowsReacquisition() throws IOException {
        FakeSessionLock sessionLock = new FakeSessionLock();
        CangshuProperties properties = properties("reacquire-root");
        Path lockFile = dataRoot(properties).resolve(WriterGate.LOCK_FILE_NAME);
        int baselineDatabase = WriterGate.registeredDatabaseSessions();
        int baselineRoots = WriterGate.registeredDataRootLocks();
        WriterGate gate = gate(properties, sessionLock);

        gate.acquire();
        assertEquals(baselineDatabase + 1, WriterGate.registeredDatabaseSessions());
        assertEquals(baselineRoots + 1, WriterGate.registeredDataRootLocks());

        gate.release();
        gate.release();   // 重复释放是幂等操作

        assertFalse(gate.holdsGate(), "释放后本实例不再持有门");
        assertEquals(1, sessionLock.releases(), "释放必须关掉持锁连接（会话结束＝数据库释放会话级锁）");
        assertEquals(baselineDatabase, WriterGate.registeredDatabaseSessions(), "登记项应当消失");
        assertEquals(baselineRoots, WriterGate.registeredDataRootLocks());
        try (FileChannel channel = FileChannel.open(lockFile, StandardOpenOption.WRITE);
                FileLock lock = channel.tryLock()) {
            assertNotNull(lock, "释放后文件锁必须真的可用（不是永久拒绝）");
        }

        gate.acquire();
        assertEquals(2, sessionLock.acquisitions(), "释放后必须能重新取锁");
        assertEquals(1, sessionLock.openHandles());
        assertTrue(gate.holdsGate());
    }

    // ── 两条失败路径 ────────────────────────────────────────────────────────────────────────

    @Test
    void deniesWhenDatabaseSessionLockIsHeldByAnotherWriter() {
        FakeSessionLock sessionLock = new FakeSessionLock().unavailable();
        CangshuProperties properties = properties("denied-database-root");
        int baselineDatabase = WriterGate.registeredDatabaseSessions();
        int baselineRoots = WriterGate.registeredDataRootLocks();
        try (CapturedLog log = captureGateLog()) {
            WriterGate gate = gate(properties, sessionLock);

            WriterGate.WriterGateDeniedException thrown =
                    assertThrows(WriterGate.WriterGateDeniedException.class, gate::acquire, "被占用的 DB 会话锁必须拒绝启动");

            assertTrue(thrown.getMessage().contains(WriterGate.REASON_DATABASE), thrown.getMessage());
            assertTrue(thrown.getMessage().contains("20260919"), thrown.getMessage());
            assertTrue(thrown.getMessage().contains("退出码 2"), thrown.getMessage());
            assertFalse(gate.holdsGate());
            assertEquals(0, sessionLock.openHandles(), "未取得锁时不得留下连接");
            assertEquals(baselineDatabase, WriterGate.registeredDatabaseSessions(), "拒绝后不得留下登记项");
            assertEquals(baselineRoots, WriterGate.registeredDataRootLocks());
            assertFalse(Files.exists(dataRoot(properties)),
                    "DB 会话锁先取；它失败时不得触碰数据根（不建目录、不建锁文件、不写字节）");
            assertTrue(log.contains(WriterGate.DENIED_MARKER + "|reason=" + WriterGate.REASON_DATABASE),
                    "门失败必须留结构化拒绝日志：" + log.lines());
        }
    }

    @Test
    void deniesWhenDatabaseIsUnreachable() {
        SQLException failure = new SQLException("Connection to 127.0.0.1:5432 refused. Check that the hostname", "08001");
        FakeSessionLock sessionLock = new FakeSessionLock().failing(failure);
        CangshuProperties properties = properties("unreachable-root");
        try (CapturedLog log = captureGateLog()) {
            WriterGate gate = gate(properties, sessionLock);

            WriterGate.WriterGateDeniedException thrown =
                    assertThrows(WriterGate.WriterGateDeniedException.class, gate::acquire, "连不上库必须拒绝启动");

            assertSame(failure, thrown.getCause(), "原始 SQLException 必须保留在因果链上");
            assertTrue(thrown.getMessage().contains(WriterGate.REASON_DATABASE), thrown.getMessage());
            assertTrue(log.contains("Connection to 127.0.0.1:5432 refused"),
                    "拒绝日志要带可诊断的失败原因：" + log.lines());
            assertFalse(Files.exists(dataRoot(properties)), "连不上库时同样不得触碰数据根");
        }
    }

    @Test
    void deniesWhenDataRootLockIsHeldAndRollsBackDatabaseSession() throws IOException {
        CangshuProperties properties = properties("contended-root");
        Path root = dataRoot(properties);
        Files.createDirectories(root);
        Path lockFile = root.resolve(WriterGate.LOCK_FILE_NAME);
        FakeSessionLock sessionLock = new FakeSessionLock();
        int baselineDatabase = WriterGate.registeredDatabaseSessions();
        int baselineRoots = WriterGate.registeredDataRootLocks();
        try (FileChannel channel = FileChannel.open(lockFile, StandardOpenOption.CREATE, StandardOpenOption.WRITE);
                FileLock held = channel.lock();   // 另一持有者（本 JVM 内）先占住数据根
                CapturedLog log = captureGateLog()) {
            WriterGate gate = gate(properties, sessionLock);

            WriterGate.WriterGateDeniedException thrown =
                    assertThrows(WriterGate.WriterGateDeniedException.class, gate::acquire, "被占用的数据根文件锁必须拒绝启动");

            assertTrue(thrown.getMessage().contains(WriterGate.REASON_DATA_ROOT), thrown.getMessage());
            assertTrue(thrown.getMessage().contains(WriterGate.LOCK_FILE_NAME), thrown.getMessage());
            assertFalse(gate.holdsGate());
            assertEquals(1, sessionLock.releases(), "文件锁失败必须回退已经拿到的 DB 会话锁");
            assertEquals(baselineDatabase, WriterGate.registeredDatabaseSessions(), "回退后不得留下 DB 会话登记");
            assertEquals(baselineRoots, WriterGate.registeredDataRootLocks());
            assertTrue(log.contains(WriterGate.DENIED_MARKER + "|reason=" + WriterGate.REASON_DATA_ROOT),
                    "门失败必须留结构化拒绝日志：" + log.lines());
        }
    }

    // ── 契约常量 ────────────────────────────────────────────────────────────────────────────

    @Test
    void gateContractValuesAreTheRegisteredOnes() {
        assertEquals(2, WriterGate.EXIT_CODE, "失锁＝退出码 2（07-运行手册 §7），不得与迁移核对的 3 混用");
        assertEquals("CANGSHU|writer-gate|acquired", WriterGate.ACQUIRED_MARKER);
        assertEquals("CANGSHU|writer-gate|denied", WriterGate.DENIED_MARKER);
        assertEquals("db-session-lock", WriterGate.REASON_DATABASE);
        assertEquals("data-root-file-lock", WriterGate.REASON_DATA_ROOT);
        assertEquals(".cangshu-writer.lock", WriterGate.LOCK_FILE_NAME, "锁文件名是协议登记值");
        assertEquals(20260919L, CangshuProperties.WRITER_LOCK_KEY, "锁键是协议常量，不随配置变化");
    }

    // ── 夹具 ────────────────────────────────────────────────────────────────────────────────

    private CangshuProperties properties(String rootName) {
        CangshuProperties properties = new CangshuProperties();
        properties.setDataRoot(temporaryDirectory.resolve(rootName).toString());
        return properties;
    }

    private static Path dataRoot(CangshuProperties properties) {
        return Path.of(properties.getDataRoot()).toAbsolutePath().normalize();
    }

    private WriterGate gate(CangshuProperties properties, WriterGate.SessionLockAcquirer sessionLocks) {
        WriterGate gate = new WriterGate(properties, DATABASE_URL, sessionLocks);
        gates.add(gate);
        return gate;
    }

    /**
     * DB 会话锁替身：不连数据库，但把「尝试次数、锁键、句柄开合、失败方式」全部记下来，
     * 使「只争抢一次」「失败要回退」这类结论可以直接断言。
     */
    private static final class FakeSessionLock implements WriterGate.SessionLockAcquirer {

        private int acquisitions;
        private int opened;
        private int releases;
        private long lastKey;
        private boolean available = true;
        private SQLException failure;

        FakeSessionLock unavailable() {
            this.available = false;
            return this;
        }

        FakeSessionLock failing(SQLException failure) {
            this.failure = failure;
            return this;
        }

        @Override
        public AutoCloseable tryAcquire(long key) throws SQLException {
            acquisitions++;
            lastKey = key;
            if (failure != null) {
                throw failure;
            }
            if (!available) {
                return null;
            }
            opened++;
            return () -> releases++;
        }

        int acquisitions() {
            return acquisitions;
        }

        int releases() {
            return releases;
        }

        int openHandles() {
            return opened - releases;
        }

        long lastKey() {
            return lastKey;
        }
    }

    /** 直接挂在 {@link WriterGate} 日志器上的行捕获：只断言门自己输出的结构化行。 */
    private static CapturedLog captureGateLog() {
        Logger logger = (Logger) LoggerFactory.getLogger(WriterGate.class);
        ListAppender<ILoggingEvent> appender = new ListAppender<>();
        appender.start();
        logger.addAppender(appender);
        return new CapturedLog(logger, appender);
    }

    private record CapturedLog(Logger logger, ListAppender<ILoggingEvent> appender) implements AutoCloseable {

        List<String> lines() {
            return appender.list.stream().map(ILoggingEvent::getFormattedMessage).toList();
        }

        boolean contains(String fragment) {
            return lines().stream().anyMatch(line -> line.contains(fragment));
        }

        @Override
        public void close() {
            logger.detachAppender(appender);
        }
    }
}
