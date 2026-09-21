package com.cangshu.catalog;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import com.cangshu.catalog.entity.ContentEntity;
import com.cangshu.catalog.mapper.ContentMapper;
import com.cangshu.catalog.mapper.ResourceMapper;
import com.cangshu.common.UuidV7;
import java.util.UUID;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.CsvSource;
import org.mockito.ArgumentCaptor;
import org.mockito.stubbing.Answer;

/**
 * 保护引用语义单元测试（catalog，任务 26；06-数据契约 §7／§8、04-架构与计划 §5 ②）。
 *
 * <p>本类覆盖状态机的逐格取值与「只在需要时写库」的守卫；「计数包含回收站行」这类
 * 依赖真实 SQL 的断言放在 {@link ReferenceSemanticsIntegrationTests}（mock 替身证明不了 WHERE 子句）。
 */
class ProtectionReferenceServiceTests {

    private ResourceMapper resourceMapper;
    private ContentMapper contentMapper;
    private ProtectionReferenceService references;

    @BeforeEach
    void setUp() {
        resourceMapper = mock(ResourceMapper.class);
        contentMapper = mock(ContentMapper.class);
        references = new ProtectionReferenceService(resourceMapper, contentMapper);
    }

    // ────────────────────────── 状态机逐格（六态 × 引用数 0／>0） ──────────────────────────

    @ParameterizedTest(name = "{0} ＋ 引用数 {1} → {2}")
    @CsvSource({
            "READY,0,RECLAIM_PENDING",
            "READY,1,READY",
            "RECLAIM_PENDING,0,RECLAIM_PENDING",
            "RECLAIM_PENDING,2,READY",
            "RECLAIMING,0,RECLAIMING",
            "RECLAIMING,3,RECLAIMING",
            "RECLAIMED,0,RECLAIMED",
            "RECLAIMED,1,RECLAIMED",
            "PENDING,0,PENDING",
            "FAILED,1,FAILED",
    })
    @DisplayName("06 §7：只有 READY↔RECLAIM_PENDING 与保护引用有关，其余状态不被计数拉动")
    void nextStatusGrid(String current, long protecting, String expected) {
        assertEquals(expected, ProtectionReferenceService.nextStatus(current, protecting));
    }

    // ────────────────────────── 计数 ──────────────────────────

    @Test
    @DisplayName("实时计数直取资源行数；替身返回 null 时按 0 处理（不抛空指针）")
    void countProtectingReadsResourceRows() {
        UUID contentId = UuidV7.generate();
        when(resourceMapper.selectCount(any())).thenReturn(2L);
        assertEquals(2L, references.countProtecting(contentId));

        when(resourceMapper.selectCount(any())).thenReturn(null);
        assertEquals(0L, references.countProtecting(contentId));
    }

    // ────────────────────────── 同步写库 ──────────────────────────

    @Test
    @DisplayName("归零：READY＋引用数 0 → 置 RECLAIM_PENDING，且只更新状态列")
    void zeroReferencesMovesReadyToReclaimPending() {
        ContentEntity content = content("READY");
        when(contentMapper.selectById(content.getId())).thenReturn(content);
        when(resourceMapper.selectCount(any())).thenReturn(0L);

        ProtectionReferenceService.SyncOutcome outcome = references.syncReclaimState(content.getId());

        assertTrue(outcome.changed());
        assertEquals("READY", outcome.statusBefore());
        assertEquals("RECLAIM_PENDING", outcome.statusAfter());
        assertEquals(0L, outcome.protectingCount());

        ArgumentCaptor<ContentEntity> patch = ArgumentCaptor.forClass(ContentEntity.class);
        verify(contentMapper, times(1)).updateById(patch.capture());
        assertEquals(content.getId(), patch.getValue().getId());
        assertEquals("RECLAIM_PENDING", patch.getValue().getStatus());
        assertNull(patch.getValue().getDigest(), "补丁只带主键与状态，不改其他列");
        assertNull(patch.getValue().getHashAlgorithm());
    }

    @Test
    @DisplayName("恢复：RECLAIM_PENDING＋引用数>0 → 回 READY（引用恢复，回到就绪）")
    void restoredReferenceMovesPendingBackToReady() {
        ContentEntity content = content("RECLAIM_PENDING");
        when(contentMapper.selectById(content.getId())).thenReturn(content);
        when(resourceMapper.selectCount(any())).thenReturn(1L);

        ProtectionReferenceService.SyncOutcome outcome = references.syncReclaimState(content.getId());

        assertTrue(outcome.changed());
        assertEquals("RECLAIM_PENDING", outcome.statusBefore());
        assertEquals("READY", outcome.statusAfter());
        verify(contentMapper, times(1)).updateById(any(ContentEntity.class));
    }

    @Test
    @DisplayName("无需变更时不写库：READY＋引用数>0 与 RECLAIM_PENDING＋引用数 0 都保持原态")
    void noUpdateWhenStatusAlreadyConsistent() {
        ContentEntity ready = content("READY");
        when(contentMapper.selectById(ready.getId())).thenReturn(ready);
        when(resourceMapper.selectCount(any())).thenReturn(5L);
        ProtectionReferenceService.SyncOutcome keptReady = references.syncReclaimState(ready.getId());
        assertFalse(keptReady.changed());
        assertEquals("READY", keptReady.statusAfter());

        ContentEntity pending = content("RECLAIM_PENDING");
        when(contentMapper.selectById(pending.getId())).thenReturn(pending);
        when(resourceMapper.selectCount(any())).thenReturn(0L);
        ProtectionReferenceService.SyncOutcome keptPending = references.syncReclaimState(pending.getId());
        assertFalse(keptPending.changed());
        assertEquals("RECLAIM_PENDING", keptPending.statusAfter());

        verify(contentMapper, never()).updateById(any(ContentEntity.class));
    }

    @Test
    @DisplayName("回收中／已回收不被计数拉动：GC 与复活路径才有权改这两个态")
    void reclaimingAndReclaimedAreNeverTouched() {
        for (String status : new String[] {"RECLAIMING", "RECLAIMED"}) {
            ContentEntity content = content(status);
            when(contentMapper.selectById(content.getId())).thenReturn(content);
            when(resourceMapper.selectCount(any())).thenAnswer(alternating());
            assertFalse(references.syncReclaimState(content.getId()).changed(), status + " 应保持不变");
        }
        verify(contentMapper, never()).updateById(any(ContentEntity.class));
    }

    @Test
    @DisplayName("内容行不存在：显式报内部错误，不静默跳过")
    void missingContentRowIsAnExplicitFailure() {
        UUID contentId = UuidV7.generate();
        when(contentMapper.selectById(contentId)).thenReturn(null);
        CatalogException e = assertThrows(CatalogException.class, () -> references.syncReclaimState(contentId));
        assertEquals(CatalogException.Code.INTERNAL_ERROR, e.code());
    }

    // ────────────────────────── 夹具 ──────────────────────────

    /** 同一测试内先后返回 0 与 1（用于同一对象上验证「归零」与「恢复」两侧都不改状态）。 */
    private static Answer<Long> alternating() {
        boolean[] first = {true};
        return invocation -> {
            long value = first[0] ? 0L : 1L;
            first[0] = false;
            return value;
        };
    }

    private static ContentEntity content(String status) {
        ContentEntity content = new ContentEntity();
        content.setId(UuidV7.generate());
        content.setHashAlgorithm("SHA-256");
        content.setDigest("ab".repeat(32));
        content.setSizeBytes(16L);
        content.setStatus(status);
        return content;
    }
}
