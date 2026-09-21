package com.cangshu.catalog;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.cangshu.common.UuidV7;
import java.util.UUID;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;

/**
 * 保护引用语义集成测试（catalog，任务 26；06-数据契约 §8、04-架构与计划 §5 ②）。
 *
 * <p>与 {@link ProtectionReferenceServiceTests} 的分工：本类用**真实 PostgreSQL** 证明两件靠替身
 * 证明不了的事——① 计数走 {@code idx_resource_content_id} 且**不过滤状态**，因此回收站行（软删的行）
 * 照样算保护引用；② 状态落库结果（不是「方法被调用过」）。
 *
 * <p>前提：本机 PostgreSQL 17 已运行且 {@code cangshu_test} 库已按 {@code db/migration/V1__init.sql}
 * 初始化（与其他集成测试共用同一库，故各测试自力清场）。
 */
@SpringBootTest(properties = {
        "spring.datasource.url=jdbc:postgresql://127.0.0.1:5432/cangshu_test?currentSchema=cangshu_m1",
        "spring.datasource.username=postgres",
        "spring.datasource.password=postgres",
        "cangshu.data-root=target/task26-ref-test-data-root"
})
class ReferenceSemanticsIntegrationTests {

    @Autowired
    JdbcTemplate jdbc;

    @Autowired
    ProtectionReferenceService references;

    @BeforeEach
    void cleanState() {
        jdbc.update("TRUNCATE cangshu_m1.resource, cangshu_m1.location, "
                + "cangshu_m1.content_conflict, cangshu_m1.content");
    }

    @Test
    @DisplayName("保护引用计数包含回收站行：软删行照样保护内容，内容不进待回收")
    void countingIncludesTrashRows() {
        UUID contentId = seedContent("READY", 8L);
        seedResource(contentId, "活跃.bin", "READY", false);
        seedResource(contentId, "已软删.bin", "DELETED", true);

        assertEquals(2L, references.countProtecting(contentId), "软删行仍在保护引用计数内（06 §8）");

        ProtectionReferenceService.SyncOutcome outcome = references.syncReclaimState(contentId);
        assertFalse(outcome.changed(), "引用未归零 → 内容保持就绪，字节不会被回收");
        assertEquals("READY", outcome.statusAfter());
        assertEquals("READY", statusOf(contentId));
    }

    @Test
    @DisplayName("引用归零才置待回收：删到最后一行才转 RECLAIM_PENDING，且落库可见")
    void lastHardDeleteMovesContentToReclaimPending() {
        UUID contentId = seedContent("READY", 8L);
        UUID keeping = seedResource(contentId, "保留.bin", "DELETED", true);
        UUID last = seedResource(contentId, "最后一行.bin", "READY", false);

        jdbc.update("DELETE FROM cangshu_m1.resource WHERE id = ?", keeping);
        assertEquals(1L, references.countProtecting(contentId));
        assertFalse(references.syncReclaimState(contentId).changed(), "尚有引用 → 不得置待回收");

        jdbc.update("DELETE FROM cangshu_m1.resource WHERE id = ?", last);
        assertEquals(0L, references.countProtecting(contentId));
        ProtectionReferenceService.SyncOutcome outcome = references.syncReclaimState(contentId);
        assertTrue(outcome.changed());
        assertEquals("RECLAIM_PENDING", outcome.statusAfter());
        assertEquals("RECLAIM_PENDING", statusOf(contentId), "状态已落库，交由 GC 异步删字节");
    }

    @Test
    @DisplayName("引用恢复：待回收内容被重新引用 → 回就绪（实时计数，无缓存延迟）")
    void newReferenceRestoresPendingContent() {
        UUID contentId = seedContent("RECLAIM_PENDING", 8L);
        assertFalse(references.syncReclaimState(contentId).changed(), "无引用时不自我循环");

        seedResource(contentId, "重新引用.bin", "READY", false);
        assertEquals(1L, references.countProtecting(contentId), "新行立即可见（实时计数）");
        assertTrue(references.syncReclaimState(contentId).changed());
        assertEquals("READY", statusOf(contentId));
    }

    @Test
    @DisplayName("回收中／已回收不被计数拉动：只有 GC 与复活路径有权改这两态")
    void gcOwnedStatusesAreLeftAlone() {
        UUID reclaiming = seedContent("RECLAIMING", 8L);
        assertFalse(references.syncReclaimState(reclaiming).changed());
        assertEquals("RECLAIMING", statusOf(reclaiming));

        UUID reclaimed = seedContent("RECLAIMED", 16L);
        seedResource(reclaimed, "复活前引用.bin", "READY", false);
        assertFalse(references.syncReclaimState(reclaimed).changed());
        assertEquals("RECLAIMED", statusOf(reclaimed), "已回收行只由同内容重传的复活路径改回就绪");
    }

    // ────────────────────────── 夹具与断言辅助 ──────────────────────────

    private UUID seedContent(String status, long sizeBytes) {
        UUID id = UuidV7.generate();
        jdbc.update("INSERT INTO cangshu_m1.content (id, hash_algorithm, digest, size_bytes, status) "
                + "VALUES (?, ?, ?, ?, ?)", id, "SHA-256", id.toString().replace("-", ""), sizeBytes, status);
        return id;
    }

    /** 回收站行必须同时给出两个时间戳（ck_resource_softdelete 等价约束）。 */
    private UUID seedResource(UUID contentId, String name, String status, boolean softDeleted) {
        UUID id = UuidV7.generate();
        if (softDeleted) {
            jdbc.update("INSERT INTO cangshu_m1.resource (id, name, size_bytes, mime_type, content_id, "
                            + "tags, status, deleted_at, expire_at) VALUES (?, ?, ?, ?, ?, '[]'::jsonb, ?, now(), "
                            + "now() + interval '7 days')",
                    id, name, 8L, "application/octet-stream", contentId, status);
        } else {
            jdbc.update("INSERT INTO cangshu_m1.resource (id, name, size_bytes, mime_type, content_id, "
                            + "tags, status) VALUES (?, ?, ?, ?, ?, '[]'::jsonb, ?)",
                    id, name, 8L, "application/octet-stream", contentId, status);
        }
        return id;
    }

    private String statusOf(UUID contentId) {
        return jdbc.queryForObject("SELECT status FROM cangshu_m1.content WHERE id = ?", String.class, contentId);
    }
}
