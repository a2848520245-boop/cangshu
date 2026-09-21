package com.cangshu.catalog;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.cangshu.ingest.StagedUpload;
import com.cangshu.ingest.UploadIngestService;
import com.cangshu.storage.FileStore;
import java.io.ByteArrayInputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardOpenOption;
import java.util.UUID;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.util.FileSystemUtils;

/**
 * 分支 C「复活复用」集成测试（catalog，任务 26；04-架构与计划 §4 分支 C 与 §5 中断续接、
 * 06-数据契约 §7 末两行）。
 *
 * <p>核心判据是「**不得只改状态**」：内容行回到就绪时，位置行与物理字节都必须真实到位。测试因此
 * 逐一断言四处证据——内容态、位置行数与键、盘上字节摘要、资源行数——而不是只看返回码。
 *
 * <p>四个复活入口各覆盖一次：已回收（字节已删）、回收中且字节已删（段二已执行）、回收中且字节仍在
 * （段二被杀在删字节前）、待回收（字节与位置行都还在）。另加两条拒止：盘上字节与内容身份不符必须
 * 409 且原行原字节不动；复活后同一内容再传必须回到普通复用（不再重建）。
 *
 * <p>前提：本机 PostgreSQL 17 已运行且 {@code cangshu_test} 库已按 {@code db/migration/V1__init.sql}
 * 初始化；数据根用独立的测试目录，测试自力清场。
 */
@SpringBootTest(properties = {
        "spring.datasource.url=jdbc:postgresql://127.0.0.1:5432/cangshu_test?currentSchema=cangshu_m1",
        "spring.datasource.username=postgres",
        "spring.datasource.password=postgres",
        "cangshu.data-root=target/task26-revival-test-data-root"
})
class ContentRevivalIntegrationTests {

    private static final Path DATA_ROOT = Path.of("target/task26-revival-test-data-root");

    @Autowired
    UploadIngestService ingest;

    @Autowired
    CatalogService catalog;

    @Autowired
    FileStore files;

    @Autowired
    JdbcTemplate jdbc;

    @BeforeEach
    void cleanState() throws Exception {
        jdbc.update("TRUNCATE cangshu_m1.resource, cangshu_m1.location, "
                + "cangshu_m1.content_conflict, cangshu_m1.content");
        FileSystemUtils.deleteRecursively(DATA_ROOT);
    }

    @Test
    @DisplayName("已回收内容重新上传：重建字节＋重建位置行，再置就绪（不得只改状态）")
    void reclaimedContentIsRevivedByRebuildingBytesAndLocationRow() throws Exception {
        byte[] bytes = "任务26：已回收内容重新上传须重建字节与位置行".getBytes(StandardCharsets.UTF_8);
        CatalogService.UploadResult first = upload("首传.bin", bytes);
        UUID contentId = first.contentId();
        String storageKey = files.storageKey("SHA-256", first.digest());

        // 模拟 GC 三段提交已完成：位置行删、字节删、内容置已回收；资源行已硬删（保护引用归零）
        jdbc.update("DELETE FROM cangshu_m1.resource");
        jdbc.update("DELETE FROM cangshu_m1.location");
        Files.delete(files.blobPath(storageKey));
        jdbc.update("UPDATE cangshu_m1.content SET status = 'RECLAIMED' WHERE id = ?", contentId);
        assertFalse(Files.exists(files.blobPath(storageKey)), "前置：字节确已不在");

        CatalogService.UploadResult revived = upload("复活.bin", bytes);

        assertTrue(revived.revived(), "命中非就绪行 → 复活标记（内部，不外露）");
        assertFalse(revived.deduplicated(), "重建了物理字节 → 不得称作复用存储（DEC-I2）");
        assertEquals(contentId, revived.contentId(), "复活原内容行，不新建第二行");
        assertEquals("READY", statusOf(contentId));
        assertEquals(1, countLocations(contentId), "位置行已重建");
        assertEquals(storageKey, storageKeyOf(contentId));
        assertTrue(Files.isRegularFile(files.blobPath(storageKey)), "物理字节已重建");
        assertEquals(first.digest(), files.sha256Hex(files.blobPath(storageKey)), "重建字节与内容身份一致");
        assertEquals(1, count("SELECT count(*) FROM cangshu_m1.content"), "内容行仍只有一条");
        assertEquals(1, count("SELECT count(*) FROM cangshu_m1.resource"), "复活后带回一条资源行");
    }

    @Test
    @DisplayName("回收中且字节已删（段二已执行）：同样按重建接上，状态不残留中间态")
    void reclaimingWithBytesAlreadyDeletedIsRevivedIdempotently() throws Exception {
        byte[] bytes = "任务26：回收中段二已删字节".getBytes(StandardCharsets.UTF_8);
        CatalogService.UploadResult first = upload("首传.bin", bytes);
        UUID contentId = first.contentId();
        String storageKey = files.storageKey("SHA-256", first.digest());

        jdbc.update("DELETE FROM cangshu_m1.resource");
        jdbc.update("DELETE FROM cangshu_m1.location");
        Files.delete(files.blobPath(storageKey));
        jdbc.update("UPDATE cangshu_m1.content SET status = 'RECLAIMING' WHERE id = ?", contentId);

        CatalogService.UploadResult revived = upload("复活.bin", bytes);

        assertTrue(revived.revived());
        assertFalse(revived.deduplicated());
        assertEquals("READY", statusOf(contentId), "RECLAIMING → READY 由复活路径完成（06 §7 末行）");
        assertEquals(1, countLocations(contentId));
        assertTrue(Files.isRegularFile(files.blobPath(storageKey)));
    }

    @Test
    @DisplayName("回收中且字节仍在（段二被杀在删字节前）：校验通过即复用，不重写字节")
    void reclaimingWithBytesPresentReusesBytesWithoutRewrite() throws Exception {
        byte[] bytes = "任务26：回收中但字节仍在该复用".getBytes(StandardCharsets.UTF_8);
        CatalogService.UploadResult first = upload("首传.bin", bytes);
        UUID contentId = first.contentId();
        String storageKey = files.storageKey("SHA-256", first.digest());
        String bytesOnDiskBefore = files.sha256Hex(files.blobPath(storageKey));

        jdbc.update("DELETE FROM cangshu_m1.resource");
        jdbc.update("DELETE FROM cangshu_m1.location");
        jdbc.update("UPDATE cangshu_m1.content SET status = 'RECLAIMING' WHERE id = ?", contentId);

        CatalogService.UploadResult revived = upload("复活.bin", bytes);

        assertTrue(revived.revived());
        assertTrue(revived.deduplicated(), "字节仍在且逐字节一致 → 本次未新增物理字节");
        assertEquals("READY", statusOf(contentId));
        assertEquals(1, countLocations(contentId), "段一删掉的位置行已补齐");
        assertEquals(bytesOnDiskBefore, files.sha256Hex(files.blobPath(storageKey)), "原字节不动");
    }

    @Test
    @DisplayName("待回收（字节与位置行都还在）：校验后置就绪，不重复插位置行")
    void reclaimPendingWithIntactBytesAndLocationIsRevived() throws Exception {
        byte[] bytes = "任务26：待回收状态复活".getBytes(StandardCharsets.UTF_8);
        CatalogService.UploadResult first = upload("首传.bin", bytes);
        UUID contentId = first.contentId();
        String storageKey = files.storageKey("SHA-256", first.digest());

        jdbc.update("DELETE FROM cangshu_m1.resource");
        jdbc.update("UPDATE cangshu_m1.content SET status = 'RECLAIM_PENDING' WHERE id = ?", contentId);
        assertEquals(1, countLocations(contentId), "前置：位置行尚未被段一删除");

        CatalogService.UploadResult revived = upload("复活.bin", bytes);

        assertTrue(revived.revived());
        assertTrue(revived.deduplicated());
        assertEquals("READY", statusOf(contentId));
        assertEquals(1, countLocations(contentId), "位置行已存在 → 不得插第二条");
        assertTrue(Files.isRegularFile(files.blobPath(storageKey)));
    }

    @Test
    @DisplayName("盘上字节与内容身份不符：复活拒绝并 409 BYTE_MISMATCH，原行原字节不动")
    void reviveRefusesByteMismatchAndLeavesOriginalRowAndBytesUntouched() throws Exception {
        byte[] bytes = "任务26：复活路径的逐字节校验（原始字节）".getBytes(StandardCharsets.UTF_8);
        CatalogService.UploadResult first = upload("首传.bin", bytes);
        UUID contentId = first.contentId();
        String storageKey = files.storageKey("SHA-256", first.digest());

        // 注入「字节与内容地址不符」：盘上换成同长度不同内容（08 故障矩阵最高危项）
        byte[] corrupted = bytes.clone();
        corrupted[0] ^= 0x7F;
        Files.write(files.blobPath(storageKey), corrupted, StandardOpenOption.TRUNCATE_EXISTING);
        String corruptedDigest = files.sha256Hex(files.blobPath(storageKey));
        jdbc.update("DELETE FROM cangshu_m1.resource");
        jdbc.update("UPDATE cangshu_m1.content SET status = 'RECLAIM_PENDING' WHERE id = ?", contentId);

        CatalogException e = assertThrows(CatalogException.class, () -> upload("复活.bin", bytes));

        assertEquals(CatalogException.Code.CONTENT_CONFLICT, e.code());
        assertEquals("BYTE_MISMATCH", e.reason(), "复活路径的字节校验与 B／E 分支同一词表（I1／I5）");
        assertEquals("RECLAIM_PENDING", statusOf(contentId), "原行不动：状态未被改写");
        assertEquals(corruptedDigest, files.sha256Hex(files.blobPath(storageKey)), "原字节不动：未被覆盖");
        assertEquals(0, count("SELECT count(*) FROM cangshu_m1.resource"), "拒绝时不新增资源行");
        assertEquals(1, count("SELECT count(*) FROM cangshu_m1.content"));
        assertEquals(1, count("SELECT count(*) FROM cangshu_m1.content_conflict WHERE reason = 'BYTE_MISMATCH'"),
                "冲突审计留痕（独立短事务）");
    }

    @Test
    @DisplayName("复活后同一内容再传：回到普通复用，不再重建、不再重复插位置行")
    void secondUploadAfterRevivalTakesTheOrdinaryReusePath() throws Exception {
        byte[] bytes = "任务26：复活之后应回到普通复用".getBytes(StandardCharsets.UTF_8);
        CatalogService.UploadResult first = upload("首传.bin", bytes);
        UUID contentId = first.contentId();
        String storageKey = files.storageKey("SHA-256", first.digest());

        jdbc.update("DELETE FROM cangshu_m1.resource");
        jdbc.update("DELETE FROM cangshu_m1.location");
        Files.delete(files.blobPath(storageKey));
        jdbc.update("UPDATE cangshu_m1.content SET status = 'RECLAIMED' WHERE id = ?", contentId);
        assertTrue(upload("复活.bin", bytes).revived());

        CatalogService.UploadResult again = upload("复活后再传.bin", bytes);

        assertFalse(again.revived(), "已是就绪行 → 走 B 普通复用，不再标记复活");
        assertTrue(again.deduplicated());
        assertEquals(contentId, again.contentId());
        assertEquals("READY", statusOf(contentId));
        assertEquals(1, countLocations(contentId));
        assertEquals(1, count("SELECT count(*) FROM cangshu_m1.content"));
        assertEquals(2, count("SELECT count(*) FROM cangshu_m1.resource"));
    }

    // ────────────────────────── 夹具与断言辅助 ──────────────────────────

    /** 走真实 ingest（流式落临时文件＋算摘要）再进 catalog 主路径，与 HTTP 路径同一入口。 */
    private CatalogService.UploadResult upload(String name, byte[] bytes) {
        StagedUpload staged = ingest.stage(new ByteArrayInputStream(bytes), (long) bytes.length);
        return catalog.upload(staged, name, "application/octet-stream");
    }

    private String statusOf(UUID contentId) {
        return jdbc.queryForObject("SELECT status FROM cangshu_m1.content WHERE id = ?", String.class, contentId);
    }

    private int countLocations(UUID contentId) {
        return count("SELECT count(*) FROM cangshu_m1.location WHERE content_id = ?", contentId);
    }

    private String storageKeyOf(UUID contentId) {
        return jdbc.queryForObject("SELECT storage_key FROM cangshu_m1.location WHERE content_id = ?",
                String.class, contentId);
    }

    private int count(String sql, Object... args) {
        Integer value = jdbc.queryForObject(sql, Integer.class, args);
        return value == null ? 0 : value;
    }
}
