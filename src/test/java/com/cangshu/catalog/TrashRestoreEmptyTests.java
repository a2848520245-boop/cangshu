package com.cangshu.catalog;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.ArgumentMatchers.isNull;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import com.cangshu.catalog.entity.ContentEntity;
import com.cangshu.catalog.entity.LocationEntity;
import com.cangshu.catalog.entity.ResourceEntity;
import com.cangshu.catalog.mapper.ContentMapper;
import com.cangshu.catalog.mapper.LocationMapper;
import com.cangshu.catalog.mapper.ResourceMapper;
import com.cangshu.catalog.mapper.TrashRow;
import com.cangshu.common.UuidV7;
import com.cangshu.config.CangshuProperties;
import com.cangshu.storage.FileStore;
import com.cangshu.storage.SegmentLockManager;
import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.OffsetDateTime;
import java.time.ZoneOffset;
import java.util.List;
import java.util.UUID;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

/**
 * 回收站的硬删与还原单元测试（catalog，任务 28；05-接口契约 §3.7／§3.8、04-架构与计划 §5 ②、
 * 08-验收规范 §5 负例）。
 *
 * <p>本类盯的是**拒止与分组**：未确认的清空一行都不能删、硬删按内容身份分组后每组只查一次引用数、
 * 字节缺失时拒绝还原。SQL 层的实际效果（时间戳被真正置空、行真的消失）由
 * {@code api.TrashEndpointsIntegrationTests} 在真实 PostgreSQL 上断言。
 */
class TrashRestoreEmptyTests {

    @TempDir
    Path tempDir;

    private ResourceMapper resourceMapper;
    private ContentMapper contentMapper;
    private LocationMapper locationMapper;
    private ProtectionReferenceService references;
    private FileStore files;
    private TrashService trash;

    @BeforeEach
    void setUp() {
        CangshuProperties properties = new CangshuProperties();
        properties.setDataRoot(tempDir.resolve("data-root").toString());
        files = new FileStore(properties);
        resourceMapper = mock(ResourceMapper.class);
        contentMapper = mock(ContentMapper.class);
        locationMapper = mock(LocationMapper.class);
        references = mock(ProtectionReferenceService.class);
        // 引用计数服务是协作对象，不是本类被测物：给它一个恒定回值，避免替身返回 null。
        when(references.syncReclaimState(any())).thenReturn(
                new ProtectionReferenceService.SyncOutcome(UuidV7.generate(), 0L, "READY", "RECLAIM_PENDING"));
        trash = new TrashService(new SegmentLockManager(), resourceMapper, contentMapper, locationMapper,
                files, references, properties, new CatalogServiceTests.PassthroughTransactionManager());
    }

    // ────────────────────────── 清空：确认负例 ──────────────────────────

    @Test
    @DisplayName("未带显式确认：400 且一行都不删（08 §5 负例）")
    void emptyTrashWithoutConfirmationDeletesNothing() {
        CatalogException e = assertThrows(CatalogException.class, () -> trash.emptyTrash(false));

        assertEquals(CatalogException.Code.INVALID_ARGUMENT, e.code());
        verify(resourceMapper, never()).delete(any());
        verify(resourceMapper, never()).findAllTrashRows();
        verify(references, never()).syncReclaimState(any());
    }

    @Test
    @DisplayName("确认后清空：按内容身份分组，每组只删一次、只同步一次引用数")
    void emptyTrashGroupsRowsByContent() {
        UUID contentA = UuidV7.generate();
        UUID contentB = UuidV7.generate();
        when(resourceMapper.findAllTrashRows()).thenReturn(List.of(
                trashRow(contentA, "SHA-256", "aa".repeat(32)),
                trashRow(contentA, "SHA-256", "aa".repeat(32)),
                trashRow(contentB, "SHA-256", "bb".repeat(32))));
        when(resourceMapper.delete(any())).thenReturn(2, 1);

        TrashService.EmptyTrashOutcome outcome = trash.emptyTrash(true);

        assertEquals(3, outcome.deletedCount());
        verify(resourceMapper, times(2)).delete(any());
        verify(references, times(1)).syncReclaimState(contentA);
        verify(references, times(1)).syncReclaimState(contentB);
    }

    @Test
    @DisplayName("到期硬删走另一条投影：只取 expire_at <= now() 的行")
    void expiredScopeUsesExpiredProjection() {
        when(resourceMapper.findExpiredTrashRows()).thenReturn(List.of());

        assertEquals(0, trash.hardDelete(TrashService.HardDeleteScope.EXPIRED));
        verify(resourceMapper, never()).findAllTrashRows();
        verify(resourceMapper, never()).delete(any());
    }

    // ────────────────────────── 还原 ──────────────────────────

    @Test
    @DisplayName("还原：清两个时间戳并回就绪，随后按内容重新计数（引用恢复）")
    void restoreClearsTimestampsAndSyncsContent() {
        UUID resourceId = UuidV7.generate();
        ResourceEntity inTrash = resource(resourceId, "DELETED", UuidV7.generate());
        ContentEntity content = content(inTrash.getContentId());
        when(resourceMapper.selectById(resourceId)).thenReturn(inTrash);
        when(contentMapper.selectById(inTrash.getContentId())).thenReturn(content);
        when(locationMapper.selectList(any())).thenReturn(List.of(location(content.getId(), keyOf(content))));
        writeBlob(keyOf(content), 16);

        TrashService.RestoreOutcome outcome = trash.restore(resourceId);

        assertTrue(outcome.changed());
        verify(resourceMapper, times(1)).update(isNull(), any());
        verify(references, times(1)).syncReclaimState(content.getId());
    }

    @Test
    @DisplayName("字节缺失：拒绝还原（08 §4 最高危项），状态一行不改")
    void restoreRefusesMissingBytes() {
        UUID resourceId = UuidV7.generate();
        ResourceEntity inTrash = resource(resourceId, "DELETED", UuidV7.generate());
        ContentEntity content = content(inTrash.getContentId());
        when(resourceMapper.selectById(resourceId)).thenReturn(inTrash);
        when(contentMapper.selectById(inTrash.getContentId())).thenReturn(content);
        when(locationMapper.selectList(any())).thenReturn(List.of(location(content.getId(), keyOf(content))));

        CatalogException e = assertThrows(CatalogException.class, () -> trash.restore(resourceId));

        assertEquals(CatalogException.Code.INTERNAL_ERROR, e.code());
        verify(resourceMapper, never()).update(any(), any());
        verify(references, never()).syncReclaimState(any());
    }

    @Test
    @DisplayName("盘上字节大小与内容身份不符：同样拒绝还原")
    void restoreRefusesSizeMismatch() throws IOException {
        UUID resourceId = UuidV7.generate();
        ResourceEntity inTrash = resource(resourceId, "DELETED", UuidV7.generate());
        ContentEntity content = content(inTrash.getContentId());
        when(resourceMapper.selectById(resourceId)).thenReturn(inTrash);
        when(contentMapper.selectById(inTrash.getContentId())).thenReturn(content);
        when(locationMapper.selectList(any())).thenReturn(List.of(location(content.getId(), keyOf(content))));
        writeBlob(keyOf(content), 8);   // 身份是 16 字节

        CatalogException e = assertThrows(CatalogException.class, () -> trash.restore(resourceId));

        assertEquals(CatalogException.Code.INTERNAL_ERROR, e.code());
        verify(resourceMapper, never()).update(any(), any());
    }

    @Test
    @DisplayName("已在活跃列表：还原是幂等无操作（不写库、不报错）")
    void restoreIsIdempotentForActiveResource() {
        UUID resourceId = UuidV7.generate();
        ResourceEntity active = resource(resourceId, "READY", UuidV7.generate());
        when(resourceMapper.selectById(resourceId)).thenReturn(active);
        when(contentMapper.selectById(active.getContentId())).thenReturn(content(active.getContentId()));

        TrashService.RestoreOutcome outcome = trash.restore(resourceId);

        assertFalse(outcome.changed());
        verify(resourceMapper, never()).update(isNull(), any());
        verify(references, never()).syncReclaimState(any());
    }

    @Test
    @DisplayName("已硬删（行不存在）：404 RESOURCE_NOT_FOUND（契约 §3.7）")
    void restoreMissingRowIsNotFound() {
        UUID resourceId = UuidV7.generate();
        when(resourceMapper.selectById(resourceId)).thenReturn(null);

        CatalogException e = assertThrows(CatalogException.class, () -> trash.restore(resourceId));

        assertEquals(CatalogException.Code.RESOURCE_NOT_FOUND, e.code());
    }

    // ────────────────────────── 夹具 ──────────────────────────

    private TrashRow trashRow(UUID contentId, String algorithm, String digest) {
        TrashRow row = new TrashRow();
        row.setResourceId(UuidV7.generate());
        row.setContentId(contentId);
        row.setHashAlgorithm(algorithm);
        row.setDigest(digest);
        return row;
    }

    private static ResourceEntity resource(UUID id, String status, UUID contentId) {
        ResourceEntity resource = new ResourceEntity();
        resource.setId(id);
        resource.setName("回收站单元测试.bin");
        resource.setSizeBytes(16L);
        resource.setContentId(contentId);
        resource.setStatus(status);
        if ("DELETED".equals(status)) {
            resource.setDeletedAt(OffsetDateTime.now(ZoneOffset.UTC).minusDays(1));
            resource.setExpireAt(OffsetDateTime.now(ZoneOffset.UTC).plusDays(6));
        }
        return resource;
    }

    private static ContentEntity content(UUID id) {
        ContentEntity content = new ContentEntity();
        content.setId(id);
        content.setHashAlgorithm("SHA-256");
        content.setDigest("ab".repeat(32));
        content.setSizeBytes(16L);
        content.setStatus("READY");
        return content;
    }

    private static LocationEntity location(UUID contentId, String storageKey) {
        LocationEntity location = new LocationEntity();
        location.setId(UuidV7.generate());
        location.setContentId(contentId);
        location.setStorageBackend("filesystem");
        location.setStorageKey(storageKey);
        return location;
    }

    private static String keyOf(ContentEntity content) {
        return "sha256/" + content.getDigest().substring(0, 2) + "/"
                + content.getDigest().substring(2, 4) + "/" + content.getDigest();
    }

    private void writeBlob(String storageKey, int size) {
        try {
            Path blob = files.blobPath(storageKey);
            Files.createDirectories(blob.getParent());
            Files.write(blob, new byte[size]);
        } catch (IOException e) {
            throw new IllegalStateException(e);
        }
    }
}
