package com.cangshu.job;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.cangshu.catalog.CatalogService;
import com.cangshu.catalog.TrashService;
import com.cangshu.config.WriterGate;
import com.cangshu.common.StagedUpload;
import com.cangshu.ingest.UploadIngestService;
import com.cangshu.storage.FileStore;
import java.io.ByteArrayInputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.attribute.FileTime;
import java.time.Duration;
import java.time.Instant;
import java.time.temporal.ChronoUnit;
import java.util.UUID;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.TimeUnit;
import java.util.function.BooleanSupplier;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.util.FileSystemUtils;

/**
 * GC 与对账的集成测试（job 模块，任务 28；04-架构与计划 §5 ③④、07-运行手册 §6、08-验收规范 §4）。
 *
 * <p>用真实 PostgreSQL ＋ 真实数据根跑作业本体，断言的是**作业做完之后的世界**：内容态、位置行、
 * 盘上字节、以及「需人工介入」这个开关。宁可慢也要真：GC 的错误后果是删掉不该删的字节。
 *
 * <p>覆盖：正常回收、引用未归零不动、到期清空、中断续接（回收中残留）、引用恢复回就绪、
 * BYTE_MISMATCH 停删并告警、连续两周期仍回收中告警；对账三条：临时文件按年龄清、孤儿隔离、
 * 缺失字节只报不自动改态。
 *
 * <p>前提：本机 PostgreSQL 17 已运行且 {@code cangshu_test} 库已初始化；数据根用独立测试目录。
 */
@SpringBootTest(properties = {
        "spring.datasource.url=jdbc:postgresql://127.0.0.1:5432/cangshu_test?currentSchema=cangshu_m1",
        "spring.datasource.username=postgres",
        "spring.datasource.password=postgres",
        "cangshu.data-root=target/task28-job-test-data-root"
})
class GcAndReconcileIntegrationTests {

    private static final Path DATA_ROOT = Path.of("target/task28-job-test-data-root");

    @Autowired
    UploadIngestService ingest;

    @Autowired
    CatalogService catalog;

    @Autowired
    TrashService trash;

    @Autowired
    GcService gc;

    @Autowired
    ReconcileService reconcile;

    @Autowired
    FileStore files;

    @Autowired
    JdbcTemplate jdbc;

    @BeforeEach
    void cleanState() throws Exception {
        jdbc.update("TRUNCATE cangshu_m1.resource, cangshu_m1.location, "
                + "cangshu_m1.content_conflict, cangshu_m1.content");
        FileSystemUtils.deleteRecursively(DATA_ROOT);
        // 夹具卫生：并发窗口用例的延时触发器绝不能跨用例存活（否则其他用例的上传会被拖慢）
        dropCommitWindowTrigger();
    }

    // ────────────────────────── GC ──────────────────────────

    @Test
    @DisplayName("最后一条引用被硬删后：GC 三段提交把内容置已回收并删字节")
    void reclaimsContentAfterLastReferenceIsGone() throws Exception {
        Fixture fixture = upload("回收.bin", "任务28：最后引用删除后回收");
        trash.softDelete(fixture.resourceId());
        assertEquals(1, trash.hardDelete(TrashService.HardDeleteScope.ALL));
        assertEquals("RECLAIM_PENDING", statusOf(fixture.contentId()), "硬删后引用归零即置待回收");

        GcService.GcRunResult result = gc.runOnce();

        assertEquals(1, result.reclaimed(), "回收队列处理一个内容");
        assertFalse(result.needsAttention(), "正常回收不该需要人工介入：" + result.notes());
        assertEquals("RECLAIMED", statusOf(fixture.contentId()));
        assertEquals(0, countLocations(fixture.contentId()), "段一删除位置行");
        assertFalse(Files.exists(fixture.blob()), "段二删除字节");
    }

    @Test
    @DisplayName("引用未归零：GC 不动内容、不动字节（软删不算归零）")
    void keepsContentWhenReferencesRemain() throws Exception {
        Fixture fixture = upload("保留.bin", "任务28：引用未归零不回收");
        trash.softDelete(fixture.resourceId());

        GcService.GcRunResult result = gc.runOnce();

        assertEquals(0, result.reclaimed());
        assertEquals("READY", statusOf(fixture.contentId()));
        assertEquals(1, countLocations(fixture.contentId()));
        assertTrue(Files.exists(fixture.blob()), "字节一根不动");
    }

    @Test
    @DisplayName("到期清空：GC 先硬删到期行，同一轮把引用归零的内容收完")
    void expiredTrashRowsAreHardDeletedThenReclaimed() throws Exception {
        Fixture fixture = upload("到期.bin", "任务28：到期自动清空");
        trash.softDelete(fixture.resourceId());
        jdbc.update("UPDATE cangshu_m1.resource SET expire_at = now() - interval '1 second' WHERE id = ?",
                fixture.resourceId());

        GcService.GcRunResult result = gc.runOnce();

        assertEquals(1, result.expiredHardDeleted(), "到期行被硬删");
        assertEquals(0, jdbc.queryForObject("SELECT count(*) FROM cangshu_m1.resource", Integer.class));
        assertEquals("RECLAIMED", statusOf(fixture.contentId()));
        assertFalse(Files.exists(fixture.blob()));
    }

    @Test
    @DisplayName("中断续接：回收中残留（段一已提交）在下一轮补齐段二段三")
    void resumesInterruptedReclaiming() throws Exception {
        Fixture fixture = upload("中断.bin", "任务28：回收中残留续接");
        trash.softDelete(fixture.resourceId());
        trash.hardDelete(TrashService.HardDeleteScope.ALL);
        // 模拟「段一已提交、段二前被杀」：位置行已删、状态停在回收中、字节还在
        jdbc.update("DELETE FROM cangshu_m1.location WHERE content_id = ?", fixture.contentId());
        jdbc.update("UPDATE cangshu_m1.content SET status = 'RECLAIMING' WHERE id = ?", fixture.contentId());

        GcService.GcRunResult result = gc.runOnce();

        assertEquals(1, result.reclaimed());
        assertEquals("RECLAIMED", statusOf(fixture.contentId()));
        assertFalse(Files.exists(fixture.blob()));
    }

    @Test
    @DisplayName("引用恢复：待回收内容又有了引用 → 回就绪，字节不删（06 §7）")
    void restoresCandidateWhenReferencesCameBack() throws Exception {
        Fixture fixture = upload("恢复.bin", "任务28：引用恢复回就绪");
        trash.softDelete(fixture.resourceId());
        trash.hardDelete(TrashService.HardDeleteScope.ALL);
        assertEquals("RECLAIM_PENDING", statusOf(fixture.contentId()));
        // 引用回来了（等价于 F 分支的幂等补齐索引行）：插一条活跃资源行指向同一内容
        jdbc.update("INSERT INTO cangshu_m1.resource (id, name, size_bytes, mime_type, content_id, tags, status) "
                        + "VALUES (?, ?, (SELECT size_bytes FROM cangshu_m1.content WHERE id = ?), "
                        + "'application/octet-stream', ?, '[]'::jsonb, 'READY')",
                com.cangshu.common.UuidV7.generate(), "重新引用.bin", fixture.contentId(), fixture.contentId());

        GcService.GcRunResult result = gc.runOnce();

        assertEquals(1, result.restoredToReady());
        assertEquals(0, result.reclaimed());
        assertEquals("READY", statusOf(fixture.contentId()));
        assertTrue(Files.exists(fixture.blob()), "字节不删");
    }

    @Test
    @DisplayName("字节与内容地址不符：不删字节、不置已回收，立即告警并停止本轮删除")
    void byteMismatchStopsDeletionAndNeedsAttention() throws Exception {
        Fixture fixture = upload("坏字节.bin", "任务28：字节与内容地址不符");
        trash.softDelete(fixture.resourceId());
        trash.hardDelete(TrashService.HardDeleteScope.ALL);
        byte[] corrupted = Files.readAllBytes(fixture.blob());
        corrupted[0] ^= 0x7F;
        Files.write(fixture.blob(), corrupted);

        GcService.GcRunResult result = gc.runOnce();

        assertEquals(1, result.byteMismatch());
        assertTrue(result.needsAttention(), "必须要求人工介入");
        // 段一（置回收中＋删位置行）是独立提交、先于段二；段二检出不符后**只**做到「不删、不置已回收」，
        // 因此行停在 RECLAIMING，并在下一轮的「连续两个周期仍回收中」告警里再次浮出水面。
        assertEquals("RECLAIMING", statusOf(fixture.contentId()), "不置已回收");
        assertEquals(0, countLocations(fixture.contentId()), "段一的位置行删除仍已生效");
        assertTrue(Files.exists(fixture.blob()), "字节不盲删");

        GcService.GcRunResult second = gc.runOnce();
        assertEquals(1, second.staleReclaiming(), "下一轮按「连续两个周期」再次告警");
    }

    @Test
    @DisplayName("连续两个 GC 周期仍为回收中：第二轮告警（阈值＝2 个周期）")
    void staleReclaimingIsAlertedOnSecondCycle() throws Exception {
        Fixture fixture = upload("卡住.bin", "任务28：连续两周期告警");
        trash.softDelete(fixture.resourceId());
        trash.hardDelete(TrashService.HardDeleteScope.ALL);
        // 造一个段一必然拒止的回收中行：位置键与内容身份不符（不删字节、停在回收中）
        jdbc.update("UPDATE cangshu_m1.location SET storage_key = ? WHERE content_id = ?",
                "sha256/cd/cd/" + "cd".repeat(32), fixture.contentId());
        jdbc.update("UPDATE cangshu_m1.content SET status = 'RECLAIMING' WHERE id = ?", fixture.contentId());

        GcService.GcRunResult first = gc.runOnce();
        assertEquals(0, first.staleReclaiming(), "第一轮只登记，不告警");
        assertTrue(first.needsAttention(), "位置异常本身已需人工介入");

        GcService.GcRunResult second = gc.runOnce();
        assertEquals(1, second.staleReclaiming(), "第二轮起按「连续两个周期」告警");
        assertTrue(second.notes().stream().anyMatch(note -> note.contains("连续两个 GC 周期")));
    }

    // ────────────────────────── 对账 ──────────────────────────

    @Test
    @DisplayName("临时文件：只清超过年龄阈值的，新临时文件不动")
    void removesOnlyOldTemporaryFiles() throws Exception {
        Path tmp = files.tmpDir();
        Files.createDirectories(tmp);
        Path old = Files.write(tmp.resolve("old-upload.tmp"), new byte[4]);
        Path fresh = Files.write(tmp.resolve("fresh-upload.tmp"), new byte[4]);
        Files.setLastModifiedTime(old, FileTime.from(
                Instant.now().minus(ReconcileService.TMP_MAX_AGE).minus(1, ChronoUnit.HOURS)));

        ReconcileService.ReconcileReport report = reconcile.runOnce();

        assertEquals(1, report.tempDeleted());
        assertFalse(Files.exists(old));
        assertTrue(Files.exists(fresh), "年轻于阈值的临时文件可能是正在进行的上传，不得删");
    }

    @Test
    @DisplayName("孤儿字节：核对摘要后隔离到 orphan/，原位置不再有该字节（绝不覆盖）")
    void quarantinesOrphanBytes() throws Exception {
        byte[] orphanBytes = "任务28：库内无位置行的孤儿字节".getBytes(StandardCharsets.UTF_8);
        String digest = sha256Hex(orphanBytes);
        String key = "sha256/" + digest.substring(0, 2) + "/" + digest.substring(2, 4) + "/" + digest;
        Path orphan = DATA_ROOT.resolve(key);
        Files.createDirectories(orphan.getParent());
        Files.write(orphan, orphanBytes);

        ReconcileService.ReconcileReport report = reconcile.runOnce();

        assertEquals(1, report.orphanFound());
        assertEquals(1, report.orphanQuarantined());
        assertEquals(0, report.orphanUntrusted(), "摘要与路径相符 → 可信");
        assertFalse(Files.exists(orphan), "原内容地址不再有该字节");
        assertTrue(Files.exists(DATA_ROOT.resolve(ReconcileService.ORPHAN_DIR).resolve(key)), "已隔离");
    }

    @Test
    @DisplayName("缺失字节：只记录并告警，不自动改状态（改状态会破坏引用语义）")
    void reportsMissingBytesWithoutChangingState() throws Exception {
        Fixture fixture = upload("缺失.bin", "任务28：就绪内容字节缺失");
        Files.delete(fixture.blob());

        ReconcileService.ReconcileReport report = reconcile.runOnce();

        assertEquals(1, report.bytesMissing());
        assertTrue(report.needsAttention());
        assertTrue(report.notes().stream().anyMatch(note -> note.contains("字节缺失")));
        assertEquals("READY", statusOf(fixture.contentId()), "状态不被对账改动");
    }

    @Test
    @DisplayName("库里位置键形状非法：记入异常并告警，不让整个作业抛异常中断（回归守卫）")
    void malformedStorageKeyIsReportedNotThrown() throws Exception {
        Fixture fixture = upload("坏键.bin", "任务28：位置键形状非法");
        // 少一段十六进制目录：形状非法。历史库（回滚前产物）里真实出现过这类键，
        // 对账遇到它必须「报告」而不是「抛异常中断」——否则启动对账会把整个服务带崩。
        jdbc.update("UPDATE cangshu_m1.location SET storage_key = ? WHERE content_id = ?",
                "sha256/cd/" + "cd".repeat(32), fixture.contentId());

        ReconcileService.ReconcileReport report = reconcile.runOnce();

        assertEquals(1, report.malformedKeys());
        assertTrue(report.needsAttention(), "坏键必须要求人工介入");
        assertTrue(report.notes().stream().anyMatch(note -> note.contains("形状非法")));
    }

    @Test
    @DisplayName("一切一致：对账不报需人工介入")
    void cleanStateHasNoAttention() throws Exception {
        Fixture fixture = upload("干净.bin", "任务28：对账干净态");
        assertTrue(Files.exists(fixture.blob()));

        ReconcileService.ReconcileReport report = reconcile.runOnce();

        assertEquals(0, report.orphanFound());
        assertEquals(0, report.bytesMissing());
        assertEquals(0, report.sizeMismatch());
        assertFalse(report.needsAttention(), "不该有告警：" + report.notes());
        assertEquals("READY", statusOf(fixture.contentId()));
    }

    // ──────────────── P0-3③ 对账共锁／门协议文件保护（04 §6 :107「六类共锁」） ────────────────

    @Test
    @DisplayName("门协议文件：持锁对账后仍在原处、未进 orphan/、不计入孤儿（同轮真孤儿照常隔离）")
    void neverTouchesWriterGateProtocolFile() throws Exception {
        Path lockFile = DATA_ROOT.resolve(WriterGate.LOCK_FILE_NAME);
        Files.createDirectories(DATA_ROOT);
        if (!Files.exists(lockFile)) {
            // 上下文启动时启动门已建好并持有它；cleanState 会重建数据根目录，这里补上同一份协议标记。
            Files.writeString(lockFile, "任务29 单写者门协议标记：不是字节对象", StandardCharsets.UTF_8);
        }
        String lockDigest = sha256Hex(Files.readAllBytes(lockFile));
        long lockSize = Files.size(lockFile);
        FileTime lockModified = Files.getLastModifiedTime(lockFile);

        // 同一轮放一个真孤儿：证明扫描确实跑过，锁文件是被「排除」，而不是「这一轮没扫」。
        byte[] orphanBytes = "任务29：与门锁文件同轮的真孤儿字节".getBytes(StandardCharsets.UTF_8);
        String orphanDigest = sha256Hex(orphanBytes);
        String orphanKey = "sha256/" + orphanDigest.substring(0, 2) + "/" + orphanDigest.substring(2, 4)
                + "/" + orphanDigest;
        Path orphan = DATA_ROOT.resolve(orphanKey);
        Files.createDirectories(orphan.getParent());
        Files.write(orphan, orphanBytes);

        ReconcileService.ReconcileReport report = reconcile.runOnce();

        assertEquals(1, report.orphanFound(), "只把真孤儿计为孤儿（门锁文件不得进候选）");
        assertEquals(1, report.orphanQuarantined());
        assertTrue(Files.isRegularFile(lockFile), "门锁文件必须仍在原路径：" + lockFile);
        assertEquals(lockDigest, sha256Hex(Files.readAllBytes(lockFile)), "门锁文件字节未被改写");
        assertEquals(lockSize, Files.size(lockFile), "门锁文件长度未变");
        assertEquals(lockModified, Files.getLastModifiedTime(lockFile), "门锁文件未被改名／重建／触碰");
        assertFalse(Files.exists(DATA_ROOT.resolve(ReconcileService.ORPHAN_DIR)
                .resolve(WriterGate.LOCK_FILE_NAME)), "门锁文件不得被隔离进 orphan/");
        assertTrue(Files.exists(DATA_ROOT.resolve(ReconcileService.ORPHAN_DIR).resolve(orphanKey)),
                "同轮的真孤儿照常隔离（证明扫描发生过）");
    }

    @Test
    @DisplayName("并发上传 vs 对账：已 moveInto、位置行未提交的字节不得被隔离（共锁＋锁内重读）")
    void concurrentUploadWindowIsNeverQuarantined() throws Exception {
        byte[] bytes = "任务29：未提交窗口内的字节，对账不得隔离".getBytes(StandardCharsets.UTF_8);
        String digest = sha256Hex(bytes);
        String key = "sha256/" + digest.substring(0, 2) + "/" + digest.substring(2, 4) + "/" + digest;
        Path blob = DATA_ROOT.resolve(key);
        Path quarantined = DATA_ROOT.resolve(ReconcileService.ORPHAN_DIR).resolve(key);

        installCommitWindowTrigger(COMMIT_WINDOW_SECONDS);
        ExecutorService worker = Executors.newSingleThreadExecutor();
        UUID contentId;
        try {
            Future<CatalogService.UploadResult> upload = worker.submit(() -> {
                StagedUpload staged = ingest.stage(new ByteArrayInputStream(bytes), (long) bytes.length);
                return catalog.upload(staged, "并发上传.bin", "application/octet-stream");
            });

            // 阻塞点：字节已 moveInto（盘上可见），事务未提交（别的连接看不到内容行）。
            awaitCondition(() -> Files.isRegularFile(blob) && contentRowsForDigest(digest) == 0,
                    Duration.ofSeconds(30), "上传进入「字节已入位、位置行未提交」的窗口");
            assertTrue(Files.isRegularFile(blob), "阻塞点上内容地址已有字节（moveInto 已完成）");
            assertEquals(0, contentRowsForDigest(digest), "阻塞点上事务未提交（锁外看不到内容行）");

            ReconcileService.ReconcileReport report = reconcile.runOnce();

            assertEquals(0, report.orphanQuarantined(), "未提交窗口内的字节不得被隔离");
            assertEquals(0, report.orphanFound(), "锁内重读后该键已登记：不算孤儿");
            assertEquals(1, report.orphanConverged(), "候选在锁内重读时已被上传登记 → 收敛");
            assertTrue(Files.isRegularFile(blob), "字节必须仍在内容地址上");
            assertFalse(Files.exists(quarantined), "不得出现隔离副本");

            contentId = upload.get(60, TimeUnit.SECONDS).contentId();
        } finally {
            worker.shutdownNow();
            dropCommitWindowTrigger();
        }

        assertEquals("READY", statusOf(contentId), "提交后内容就绪");
        assertEquals(1, countLocations(contentId), "位置行已在");
        assertEquals(digest, sha256Hex(Files.readAllBytes(blob)), "正式字节与内容身份一致");

        ReconcileService.ReconcileReport second = reconcile.runOnce();
        assertEquals(0, second.orphanFound(), "已登记键不再算孤儿");
        assertEquals(0, second.bytesMissing(), "无缺失字节");
        assertFalse(second.needsAttention(), "对账收敛、无告警：" + second.notes());
        assertTrue(Files.isRegularFile(blob), "字节仍在原位");
    }

    /** 延时触发器名／函数名与睡眠秒数（普通触发器：不进 pg_constraint，对 DEC-T3 结构门无影响）。 */
    private static final String COMMIT_WINDOW_TRIGGER = "cangshu_test_commit_window";
    private static final String COMMIT_WINDOW_FUNCTION = "cangshu_test_commit_window_gate";
    private static final int COMMIT_WINDOW_SECONDS = 5;

    /** 把上传事务卡在「已 moveInto、行未提交」窗口（resource 插入后、COMMIT 前）的夹具。 */
    private void installCommitWindowTrigger(int sleepSeconds) {
        jdbc.execute("CREATE OR REPLACE FUNCTION cangshu_m1." + COMMIT_WINDOW_FUNCTION
                + "() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN PERFORM pg_sleep(" + sleepSeconds
                + "); RETURN COALESCE(NEW, OLD); END $$");
        jdbc.execute("DROP TRIGGER IF EXISTS " + COMMIT_WINDOW_TRIGGER + " ON cangshu_m1.resource");
        jdbc.execute("CREATE TRIGGER " + COMMIT_WINDOW_TRIGGER
                + " AFTER INSERT ON cangshu_m1.resource FOR EACH ROW EXECUTE FUNCTION cangshu_m1."
                + COMMIT_WINDOW_FUNCTION + "()");
    }

    private void dropCommitWindowTrigger() {
        jdbc.execute("DROP TRIGGER IF EXISTS " + COMMIT_WINDOW_TRIGGER + " ON cangshu_m1.resource");
        jdbc.execute("DROP FUNCTION IF EXISTS cangshu_m1." + COMMIT_WINDOW_FUNCTION + "()");
    }

    /** 锁外可见的内容行数（未提交事务的行对别的连接不可见＝0）。 */
    private int contentRowsForDigest(String digest) {
        Integer count = jdbc.queryForObject(
                "SELECT count(*) FROM cangshu_m1.content WHERE digest = ?", Integer.class, digest);
        return count == null ? 0 : count;
    }

    private static void awaitCondition(BooleanSupplier condition, Duration timeout, String description)
            throws InterruptedException {
        Instant deadline = Instant.now().plus(timeout);
        while (Instant.now().isBefore(deadline)) {
            if (condition.getAsBoolean()) {
                return;
            }
            Thread.sleep(50L);
        }
        throw new AssertionError("等待超时（" + timeout.toSeconds() + " 秒）：" + description);
    }

    // ────────────────────────── 夹具 ──────────────────────────

    private record Fixture(UUID resourceId, UUID contentId, Path blob) {
    }

    private Fixture upload(String name, String text) {
        byte[] bytes = text.getBytes(StandardCharsets.UTF_8);
        StagedUpload staged = ingest.stage(new ByteArrayInputStream(bytes), (long) bytes.length);
        CatalogService.UploadResult result = catalog.upload(staged, name, "application/octet-stream");
        String key = files.storageKey("SHA-256", result.digest());
        return new Fixture(result.resourceId(), result.contentId(), files.blobPath(key));
    }

    private String statusOf(UUID contentId) {
        return jdbc.queryForObject("SELECT status FROM cangshu_m1.content WHERE id = ?", String.class, contentId);
    }

    private int countLocations(UUID contentId) {
        Integer value = jdbc.queryForObject(
                "SELECT count(*) FROM cangshu_m1.location WHERE content_id = ?", Integer.class, contentId);
        return value == null ? 0 : value;
    }

    private static String sha256Hex(byte[] bytes) throws Exception {
        return java.util.HexFormat.of().formatHex(
                java.security.MessageDigest.getInstance("SHA-256").digest(bytes));
    }
}
