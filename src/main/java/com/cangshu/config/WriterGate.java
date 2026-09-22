package com.cangshu.config;

import com.zaxxer.hikari.HikariDataSource;
import jakarta.annotation.PostConstruct;
import jakarta.annotation.PreDestroy;
import java.io.IOException;
import java.nio.channels.FileChannel;
import java.nio.channels.FileLock;
import java.nio.channels.OverlappingFileLockException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardOpenOption;
import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.util.Locale;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import javax.sql.DataSource;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.stereotype.Component;

/**
 * 单写者启动门（DEC-T2：ADR-0001 §四、04-架构与计划 §6／§8 步骤 1、03 REQ-M1-14、07-运行手册 §7）。
 *
 * <p><b>行为</b>：启动时取两把锁——DB 会话锁（PostgreSQL 会话级咨询锁，键＝
 * {@link CangshuProperties#WRITER_LOCK_KEY}）与数据根文件锁（{@code <data-root>/.cangshu-writer.lock}
 * 的 {@link FileChannel} 独占锁）。两把都拿到才继续；任一失败即停写：抛
 * {@link WriterGateDeniedException}，应用入口把它映射为退出码 {@value #EXIT_CODE}，
 * 不写任何业务字节、不出 Tomcat 监听、无降级开关（没有任何配置键或环境变量能绕过本门）。
 *
 * <p><b>启动顺序</b>：本门必须先于迁移只读核对（04 §8 步骤 1→2）。保证方式是 Bean 依赖而不是偶然顺序：
 * {@code SchemaVerifier} 用 {@code @DependsOn("writerGate")} 声明依赖本组件，因此本组件的
 * {@code @PostConstruct} 一定先跑完。门失败时核对不运行，Tomcat 连接器也不会开始监听
 * （连接器在上下文 refresh 收尾才启动）。
 *
 * <p><b>进程级单写者语义</b>：跨进程必须互斥；同一 JVM 内重复获取则幂等复用已持有的锁。
 * 生产语义本来就是「一个进程一个写者」，而测试套件会在同一 JVM 里为不同 {@code cangshu.data-root}
 * 启动多个 Spring 上下文：若每个上下文都真抢锁，第二个上下文必然失锁。
 * 因此两把锁各自有 JVM 级静态登记与引用计数：
 *
 * <ul>
 *   <li>DB 会话锁按 <b>DB URL</b> 登记（PostgreSQL 咨询锁按库、按会话冲突：同一 JVM 同库多上下文
 *       共用一条已持锁的连接，不重复调用 {@code pg_try_advisory_lock}）；</li>
 *   <li>数据根文件锁按 <b>规范化数据根</b> 登记（同一 JVM 对同一文件的第二次 {@code tryLock}
 *       会抛 {@link OverlappingFileLockException}，故同一数据根本身也必须复用）。</li>
 * </ul>
 *
 * <p>登记在上下文关闭时按引用计数递减、归零才真正放锁；JVM 退出时由关闭钩子兜底释放。
 *
 * <p><b>锁载体与持有方式</b>：
 *
 * <ul>
 *   <li>DB 侧：一条<b>不经连接池</b>的连接（{@link DriverManager} 直连数据源实际生效的
 *       URL 与凭据）。会话级锁随持有连接消失而释放，而池会按空闲回收／{@code maxLifetime}
 *       关掉池内连接，锁会顺手失效——所以绝不用 {@code DataSource#getConnection()} 持锁。</li>
 *   <li>数据根侧：{@code .cangshu-writer.lock} 上的独占文件锁，随通道关闭释放。</li>
 *   <li>数据根不存在时创建目录与锁文件；该 {@code .lock} 文件是协议标记，<b>不算业务字节</b>。</li>
 * </ul>
 */
@Component("writerGate")
public class WriterGate {

    /** 门失败＝「未拿到 DB 会话锁或数据根文件锁」→ 退出码 2（07 §7；03 REQ-M1-14；04 §8 步骤 1）。 */
    public static final int EXIT_CODE = 2;

    /** 数据根下的文件锁文件名（协议登记值，不随配置变化）。 */
    public static final String LOCK_FILE_NAME = ".cangshu-writer.lock";

    /** 门获取成功日志标记；{@code reusedDb}／{@code reusedDataRoot} 表示该锁来自 JVM 内既有持有。 */
    public static final String ACQUIRED_MARKER = "CANGSHU|writer-gate|acquired";

    /** 门被拒绝日志标记；{@code reason} 区分 {@value #REASON_DATABASE} 与 {@value #REASON_DATA_ROOT}。 */
    public static final String DENIED_MARKER = "CANGSHU|writer-gate|denied";

    /** 释放日志标记（引用计数归零或递减）。 */
    public static final String RELEASED_MARKER = "CANGSHU|writer-gate|released";

    /** 拒绝原因：DB 会话锁未取得。 */
    public static final String REASON_DATABASE = "db-session-lock";

    /** 拒绝原因：数据根文件锁未取得。 */
    public static final String REASON_DATA_ROOT = "data-root-file-lock";

    private static final Logger log = LoggerFactory.getLogger(WriterGate.class);

    /** JVM 级登记：DB URL → 该库上被本 JVM 持有的会话锁连接。 */
    private static final Map<String, DatabaseSession> DATABASE_SESSIONS = new ConcurrentHashMap<>();

    /** JVM 级登记：规范化数据根 → 该数据根上被本 JVM 持有的文件锁。 */
    private static final Map<String, DataRootLock> DATA_ROOT_LOCKS = new ConcurrentHashMap<>();

    /** 两张登记表的互斥体：静态，从而跨 Spring 上下文（同 JVM 内多个上下文＝多个实例）串行。 */
    private static final Object GATE = new Object();

    private static volatile boolean shutdownHookRegistered;

    private final CangshuProperties properties;
    private final String databaseUrl;
    private final String dataRootKey;
    private final SessionLockAcquirer sessionLocks;

    private Held held;

    @Autowired
    public WriterGate(DataSource dataSource, CangshuProperties properties) {
        this(properties, jdbcUrlOf(dataSource), new PostgresSessionLock(dataSource));
    }

    /**
     * 测试注入面：数据库标识与 DB 会话锁的获取方式可替换（数据根文件锁仍走真实实现）。
     * 上面那个构造器显式标 {@code @Autowired}，Spring 才不会在多个构造器之间犹豫。
     */
    WriterGate(CangshuProperties properties, String databaseUrl, SessionLockAcquirer sessionLocks) {
        this.properties = properties;
        this.databaseUrl = databaseUrl;
        this.dataRootKey = normalizeDataRoot(properties.getDataRoot());
        this.sessionLocks = sessionLocks;
    }

    /** 启动门（04 §8 步骤 1）：本组件构造完成后立刻取锁。 */
    @PostConstruct
    public void acquireAtStartup() {
        acquire();
    }

    /** 上下文关闭时释放本实例的登记（引用计数递减；归零才真正放锁）。 */
    @PreDestroy
    public void releaseAtShutdown() {
        release();
    }

    /**
     * 取门：两把锁都拿到才算通过；已持有的锁按 JVM 级登记复用，不重复争抢。
     *
     * @throws WriterGateDeniedException 任一锁未取得
     */
    public void acquire() {
        synchronized (GATE) {
            DatabaseSession session = DATABASE_SESSIONS.get(databaseUrl);
            boolean reusedDatabase = session != null;
            if (session == null) {
                session = new DatabaseSession(acquireSessionLock());
                DATABASE_SESSIONS.put(databaseUrl, session);
            }
            try {
                DataRootLock rootLock = DATA_ROOT_LOCKS.get(dataRootKey);
                boolean reusedDataRoot = rootLock != null;
                if (rootLock == null) {
                    rootLock = lockDataRoot();
                    DATA_ROOT_LOCKS.put(dataRootKey, rootLock);
                }
                session.references++;
                rootLock.references++;
                held = new Held(session, rootLock);
                registerShutdownHookOnce();
                log.info("{}|reused={}|reusedDb={}|reusedDataRoot={}|dbUrl={}|dataRoot={}|lockFile={}|writerLockKey={}",
                        ACQUIRED_MARKER, reusedDatabase && reusedDataRoot, reusedDatabase, reusedDataRoot,
                        databaseUrl, dataRoot(), dataRoot().resolve(LOCK_FILE_NAME),
                        CangshuProperties.WRITER_LOCK_KEY);
            } catch (RuntimeException exception) {
                // 文件锁失败＝门失败：本次新建的 DB 会话锁必须立刻回退，不能留在登记表里冒充持有。
                if (!reusedDatabase) {
                    DATABASE_SESSIONS.remove(databaseUrl, session);
                    session.close();
                }
                throw exception;
            }
        }
    }

    /** 释放本实例的一次登记：未持有或重复调用都是无操作。 */
    public void release() {
        synchronized (GATE) {
            Held current = held;
            held = null;
            if (current == null) {
                return;
            }
            int remainingDatabase = --current.session.references;
            if (remainingDatabase == 0) {
                DATABASE_SESSIONS.remove(databaseUrl, current.session);
                current.session.close();
            }
            int remainingDataRoot = --current.rootLock.references;
            if (remainingDataRoot == 0) {
                DATA_ROOT_LOCKS.remove(dataRootKey, current.rootLock);
                current.rootLock.close();
            }
            log.info("{}|releasedDb={}|releasedDataRoot={}|remainingDbReferences={}|remainingDataRootReferences={}"
                            + "|dbUrl={}|dataRoot={}",
                    RELEASED_MARKER, remainingDatabase == 0, remainingDataRoot == 0,
                    remainingDatabase, remainingDataRoot, databaseUrl, dataRoot());
        }
    }

    /** 本实例当前是否持有门（测试与诊断用）。 */
    public boolean holdsGate() {
        Held current = held;
        return current != null
                && DATABASE_SESSIONS.get(databaseUrl) == current.session
                && DATA_ROOT_LOCKS.get(dataRootKey) == current.rootLock;
    }

    /** 测试与诊断用：本 JVM 当前登记的 DB 会话锁条数（按 DB URL 计）。 */
    static int registeredDatabaseSessions() {
        return DATABASE_SESSIONS.size();
    }

    /** 测试与诊断用：本 JVM 当前登记的数据根文件锁条数（按规范化数据根计）。 */
    static int registeredDataRootLocks() {
        return DATA_ROOT_LOCKS.size();
    }

    /** 数据根的规范绝对路径（07 §1：启动解析并记录规范绝对路径）。 */
    private Path dataRoot() {
        return Path.of(properties.getDataRoot()).toAbsolutePath().normalize();
    }

    /** 取 DB 会话锁；未取得或调用失败都按门失败处理。 */
    private AutoCloseable acquireSessionLock() {
        AutoCloseable sessionLock;
        try {
            sessionLock = sessionLocks.tryAcquire(CangshuProperties.WRITER_LOCK_KEY);
        } catch (SQLException exception) {
            throw deny(REASON_DATABASE,
                    "DB 会话锁无法获取（连接或咨询锁调用失败）：" + exception.getMessage(), exception);
        }
        if (sessionLock == null) {
            throw deny(REASON_DATABASE, "DB 会话锁已被其它写者持有：" + databaseUrl
                    + "（键 " + CangshuProperties.WRITER_LOCK_KEY + "）", null);
        }
        return sessionLock;
    }

    /** 取数据根文件锁（独占）；目录不存在时创建目录与锁文件。 */
    private DataRootLock lockDataRoot() {
        Path lockFile = dataRoot().resolve(LOCK_FILE_NAME);
        FileChannel channel = null;
        try {
            Files.createDirectories(dataRoot());
            channel = FileChannel.open(lockFile, StandardOpenOption.CREATE, StandardOpenOption.WRITE);
            FileLock fileLock = channel.tryLock();
            if (fileLock == null) {
                closeQuietly(channel);
                throw deny(REASON_DATA_ROOT, "数据根文件锁已被其它进程持有：" + lockFile, null);
            }
            return new DataRootLock(channel, fileLock, lockFile);
        } catch (OverlappingFileLockException exception) {
            closeQuietly(channel);
            throw deny(REASON_DATA_ROOT, "数据根文件锁已被同一 JVM 的另一持有者占用：" + lockFile, exception);
        } catch (IOException exception) {
            closeQuietly(channel);
            throw deny(REASON_DATA_ROOT,
                    "数据根文件锁无法获取：" + lockFile + "（" + exception.getMessage() + "）", exception);
        }
    }

    /** 门失败：记结构化日志（含拒绝原因）并返回退出码 2 对应的异常。 */
    private WriterGateDeniedException deny(String reason, String detail, Throwable cause) {
        String line = "reason=" + reason
                + "|dbUrl=" + databaseUrl
                + "|dataRoot=" + dataRoot()
                + "|lockFile=" + dataRoot().resolve(LOCK_FILE_NAME)
                + "|writerLockKey=" + CangshuProperties.WRITER_LOCK_KEY
                + "|detail=" + detail;
        if (cause == null) {
            log.error("{}|{}", DENIED_MARKER, line);
        } else {
            log.error("{}|{}", DENIED_MARKER, line, cause);
        }
        String message = "单写者启动门拒绝（" + reason + "）：" + detail
                + "；停写，退出码 " + EXIT_CODE + "，不写任何字节（07-运行手册 §7）";
        return cause == null ? new WriterGateDeniedException(message) : new WriterGateDeniedException(message, cause);
    }

    /** JVM 退出兜底释放；与 {@link #release()} 同样幂等。 */
    private static void releaseAll() {
        synchronized (GATE) {
            DATABASE_SESSIONS.forEach((key, session) -> {
                DATABASE_SESSIONS.remove(key, session);
                session.close();
            });
            DATA_ROOT_LOCKS.forEach((key, rootLock) -> {
                DATA_ROOT_LOCKS.remove(key, rootLock);
                rootLock.close();
            });
        }
    }

    /** 调用方持有 {@link #GATE}。 */
    private static void registerShutdownHookOnce() {
        if (shutdownHookRegistered) {
            return;
        }
        Runtime.getRuntime().addShutdownHook(new Thread(WriterGate::releaseAll, "cangshu-writer-gate-shutdown"));
        shutdownHookRegistered = true;
    }

    private static void closeQuietly(AutoCloseable closeable) {
        if (closeable == null) {
            return;
        }
        try {
            closeable.close();
        } catch (Exception exception) {
            log.warn("CANGSHU|writer-gate|release-failed|detail={}", exception.toString());
        }
    }

    /** 登记键里的数据根：规范绝对路径；Windows 大小写不敏感，故按小写归并，避免同一目录生成两个键。 */
    private static String normalizeDataRoot(String rawDataRoot) {
        String normalized = Path.of(rawDataRoot).toAbsolutePath().normalize().toString();
        return System.getProperty("os.name", "").toLowerCase(Locale.ROOT).startsWith("windows")
                ? normalized.toLowerCase(Locale.ROOT) : normalized;
    }

    /** 单写者门的登记键之一：数据源实际生效的 JDBC URL（DB 侧锁按库冲突，故 URL 必须参与登记）。 */
    static String jdbcUrlOf(DataSource dataSource) {
        if (dataSource instanceof HikariDataSource hikari && hikari.getJdbcUrl() != null) {
            return hikari.getJdbcUrl();
        }
        try (Connection probe = dataSource.getConnection()) {
            return probe.getMetaData().getURL();
        } catch (SQLException exception) {
            throw new IllegalStateException(
                    "无法解析数据源 JDBC URL：单写者启动门需要它作为登记键（不降级、不跳过门）", exception);
        }
    }

    /** 同一 JVM 内被持有的一条 DB 会话锁连接（引用计数＝几个上下文在用）。 */
    private static final class DatabaseSession {

        private final AutoCloseable handle;
        private int references;

        DatabaseSession(AutoCloseable handle) {
            this.handle = handle;
        }

        /** 关闭连接即结束会话，数据库随之释放会话级咨询锁。 */
        void close() {
            closeQuietly(handle);
        }
    }

    /** 同一 JVM 内被持有的一个数据根文件锁（引用计数＝几个上下文在用）。 */
    private static final class DataRootLock {

        private final FileChannel channel;
        private final FileLock fileLock;
        private final Path lockFile;
        private int references;

        DataRootLock(FileChannel channel, FileLock fileLock, Path lockFile) {
            this.channel = channel;
            this.fileLock = fileLock;
            this.lockFile = lockFile;
        }

        void close() {
            closeQuietly(fileLock);
            closeQuietly(channel);
            log.info("CANGSHU|writer-gate|file-lock-released|lockFile={}", lockFile);
        }
    }

    /** 本实例的一次登记：两把锁各自的登记项。 */
    private record Held(DatabaseSession session, DataRootLock rootLock) {
    }

    /**
     * DB 会话锁的获取面：成功返回持有句柄（关闭即释放会话）、未取得返回 {@code null}、调用失败抛
     * {@link SQLException}。抽出这一层是为了让门的三条分支（成功／被占／连不上）都能在单测里覆盖，
     * 而不必依赖共享 PostgreSQL；生产实现见 {@link PostgresSessionLock}。
     */
    interface SessionLockAcquirer {

        AutoCloseable tryAcquire(long key) throws SQLException;
    }

    /**
     * PostgreSQL 会话级咨询锁（{@code pg_try_advisory_lock}）。
     *
     * <p>连接**独立于连接池**：会话级锁跟随持有它的连接，池会按空闲回收／{@code maxLifetime}
     * 关闭池内连接，锁会随着连接消失而失效；因此这里用数据源实际生效的 URL 与凭据经
     * {@link DriverManager} 另开一条物理连接，由门持有到进程退出或显式释放（CLI 与 serve 同此协议，07 §2）。
     */
    static final class PostgresSessionLock implements SessionLockAcquirer {

        private final DataSource dataSource;

        PostgresSessionLock(DataSource dataSource) {
            this.dataSource = dataSource;
        }

        @Override
        public AutoCloseable tryAcquire(long key) throws SQLException {
            Connection connection = openDedicatedConnection();
            boolean acquired = false;
            try {
                // 会话级锁（非事务级）：不需要事务，连接存续期间一直有效。
                try (PreparedStatement statement = connection.prepareStatement("SELECT pg_try_advisory_lock(?)")) {
                    statement.setLong(1, key);
                    try (ResultSet result = statement.executeQuery()) {
                        acquired = result.next() && result.getBoolean(1);
                    }
                }
            } finally {
                if (!acquired) {
                    connection.close();   // 未取得：这条连接只是探测用的，立即还给操作系统
                }
            }
            return acquired ? connection::close : null;
        }

        private Connection openDedicatedConnection() throws SQLException {
            if (dataSource instanceof HikariDataSource hikari && hikari.getJdbcUrl() != null) {
                String driverClassName = hikari.getDriverClassName();
                if (driverClassName != null && !driverClassName.isBlank()) {
                    // 打包 jar 下显式加载驱动，确保已向 DriverManager 注册（不依赖 ServiceLoader 的类加载细节）。
                    try {
                        Class.forName(driverClassName);
                    } catch (ClassNotFoundException exception) {
                        throw new SQLException("JDBC 驱动类不可用：" + driverClassName, exception);
                    }
                }
                return DriverManager.getConnection(hikari.getJdbcUrl(), hikari.getUsername(), hikari.getPassword());
            }
            // 非 Hikari 数据源（本工程默认栈不会走到）退化为「检出后长期不归还」，同样避开空闲回收。
            return dataSource.getConnection();
        }
    }

    /**
     * 单写者门失败：未拿到 DB 会话锁或数据根文件锁。
     *
     * <p>独立异常类型，使应用入口能稳定地把「失锁」映射为退出码 {@value WriterGate#EXIT_CODE}，
     * 不与迁移只读核对的退出码 3（{@code MigrationVerificationException}）混用。
     */
    public static final class WriterGateDeniedException extends RuntimeException {

        public WriterGateDeniedException(String message) {
            super(message);
        }

        public WriterGateDeniedException(String message, Throwable cause) {
            super(message, cause);
        }
    }
}
