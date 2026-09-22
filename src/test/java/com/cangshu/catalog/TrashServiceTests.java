package com.cangshu.catalog;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotNull;
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
import com.cangshu.catalog.entity.ResourceEntity;
import com.cangshu.catalog.mapper.ContentMapper;
import com.cangshu.catalog.mapper.LocationMapper;
import com.cangshu.catalog.mapper.ResourceMapper;
import com.cangshu.common.UuidV7;
import com.cangshu.config.CangshuProperties;
import com.cangshu.config.WriterGate;
import com.cangshu.storage.FileStore;
import com.cangshu.storage.SegmentLockManager;
import java.nio.file.Path;
import java.time.Duration;
import java.time.OffsetDateTime;
import java.time.ZoneOffset;
import java.util.UUID;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;
import org.mockito.ArgumentCaptor;

/**
 * 软删单元测试（catalog，任务 6；05-接口契约 §3.5、04-架构与计划 §5 ①、06-数据契约 §7／§8）。
 *
 * <p>本类的重点是**写出去的补丁长什么样**与**不该写的时候一行都不写**：置删除态必须同时给出
 * 软删时刻与固定到期时刻（数据库 ck_resource_softdelete 有等价约束），而重复软删必须幂等、
 * 不刷新首次到期时刻。mapper 用 Mockito 替身；事务用直通管理器（替身 mapper 不产生真实 SQL）。
 */
class TrashServiceTests {

    private static final Duration SEVEN_DAYS = Duration.ofDays(7);

    @TempDir
    Path tempDir;

    private ResourceMapper resourceMapper;
    private ContentMapper contentMapper;
    private LocationMapper locationMapper;
    private ProtectionReferenceService references;
    private FileStore files;
    private CangshuProperties properties;
    private TrashService trash;

    @BeforeEach
    void setUp() {
        properties = new CangshuProperties();
        properties.setDataRoot(tempDir.resolve("data-root").toString());
        files = new FileStore(Path.of(properties.getDataRoot()).toAbsolutePath().normalize(),
                WriterGate.LOCK_FILE_NAME);
        resourceMapper = mock(ResourceMapper.class);
        contentMapper = mock(ContentMapper.class);
        locationMapper = mock(LocationMapper.class);
        references = mock(ProtectionReferenceService.class);
        trash = new TrashService(new SegmentLockManager(), resourceMapper, contentMapper, locationMapper,
                files, references, properties, new CatalogServiceTests.PassthroughTransactionManager());
    }

    // ────────────────────────── 软删正例 ──────────────────────────

    @Test
    @DisplayName("软删就绪资源：补丁只带状态与三个时间列，到期时刻＝软删时刻＋保留期")
    void softDeleteWritesDeletionStateAndFixedExpiry() {
        UUID resourceId = UuidV7.generate();
        ResourceEntity ready = resource(resourceId, "READY");
        when(resourceMapper.selectById(resourceId)).thenReturn(ready);
        when(contentMapper.selectById(ready.getContentId())).thenReturn(content(ready.getContentId()));

        TrashService.SoftDeleteOutcome outcome = trash.softDelete(resourceId);

        assertFalse(outcome.alreadyInTrash());
        assertEquals(resourceId, outcome.resourceId());

        ArgumentCaptor<ResourceEntity> patch = ArgumentCaptor.forClass(ResourceEntity.class);
        verify(resourceMapper, times(1)).updateById(patch.capture());
        assertEquals(resourceId, patch.getValue().getId());
        assertEquals("DELETED", patch.getValue().getStatus());
        assertNotNull(patch.getValue().getDeletedAt());
        assertNotNull(patch.getValue().getExpireAt());
        assertEquals(SEVEN_DAYS, Duration.between(patch.getValue().getDeletedAt(), patch.getValue().getExpireAt()),
                "到期时刻＝软删时刻＋固定保留期（06 §8 默认 7 天）");
        assertEquals(patch.getValue().getDeletedAt(), patch.getValue().getUpdatedAt());
        assertEquals(outcome.expireAt(), patch.getValue().getExpireAt());

        // 只删引用：补丁不得触碰身份列与内容关联（一旦带上就会被 updateById 覆盖）
        assertNull(patch.getValue().getName());
        assertNull(patch.getValue().getSizeBytes());
        assertNull(patch.getValue().getContentId());
        assertNull(patch.getValue().getMimeType());
        assertNull(patch.getValue().getTags());
    }

    @Test
    @DisplayName("保留期为 0（测试可配置）：到期时刻等于软删时刻")
    void zeroRetentionMakesExpiryEqualDeletionTime() {
        properties.getTrash().setRetention(Duration.ZERO);
        UUID resourceId = UuidV7.generate();
        ResourceEntity ready = resource(resourceId, "READY");
        when(resourceMapper.selectById(resourceId)).thenReturn(ready);
        when(contentMapper.selectById(ready.getContentId())).thenReturn(content(ready.getContentId()));

        trash.softDelete(resourceId);

        ArgumentCaptor<ResourceEntity> patch = ArgumentCaptor.forClass(ResourceEntity.class);
        verify(resourceMapper, times(1)).updateById(patch.capture());
        assertEquals(patch.getValue().getDeletedAt(), patch.getValue().getExpireAt());
    }

    // ────────────────────────── 幂等 ──────────────────────────

    @Test
    @DisplayName("软删幂等：已在回收站则原样返回首次时刻，一行都不写（不刷新到期时刻）")
    void repeatedSoftDeleteKeepsFirstExpiryAndWritesNothing() {
        UUID resourceId = UuidV7.generate();
        OffsetDateTime firstDeletedAt = OffsetDateTime.now(ZoneOffset.UTC).minusDays(1);
        OffsetDateTime firstExpireAt = firstDeletedAt.plus(SEVEN_DAYS);
        ResourceEntity inTrash = resource(resourceId, "DELETED");
        inTrash.setDeletedAt(firstDeletedAt);
        inTrash.setExpireAt(firstExpireAt);
        when(resourceMapper.selectById(resourceId)).thenReturn(inTrash);

        TrashService.SoftDeleteOutcome outcome = trash.softDelete(resourceId);

        assertTrue(outcome.alreadyInTrash());
        assertEquals(firstDeletedAt, outcome.deletedAt(), "首次软删时刻不被刷新");
        assertEquals(firstExpireAt, outcome.expireAt(), "保留期不因重复删除而被无限延长（06 §8）");
        verify(resourceMapper, never()).updateById(any(ResourceEntity.class));
        verify(contentMapper, never()).selectById(any());
    }

    @Test
    @DisplayName("锁内发现已被并发软删：按幂等返回首次时刻，同样一行都不写")
    void idempotentBranchInsideLockWritesNothing() {
        UUID resourceId = UuidV7.generate();
        OffsetDateTime firstDeletedAt = OffsetDateTime.now(ZoneOffset.UTC).minusHours(2);
        OffsetDateTime firstExpireAt = firstDeletedAt.plus(SEVEN_DAYS);
        ResourceEntity ready = resource(resourceId, "READY");
        ResourceEntity wonByOther = resource(resourceId, "DELETED");
        wonByOther.setDeletedAt(firstDeletedAt);
        wonByOther.setExpireAt(firstExpireAt);
        // 锁外读看到 READY（所以走了取锁路径），锁内重读已是 DELETED（另一路抢先完成软删）
        when(resourceMapper.selectById(resourceId)).thenReturn(ready, wonByOther);
        when(contentMapper.selectById(ready.getContentId())).thenReturn(content(ready.getContentId()));

        TrashService.SoftDeleteOutcome outcome = trash.softDelete(resourceId);

        assertTrue(outcome.alreadyInTrash());
        assertEquals(firstDeletedAt, outcome.deletedAt());
        assertEquals(firstExpireAt, outcome.expireAt());
        verify(resourceMapper, never()).updateById(any(ResourceEntity.class));
    }

    // ────────────────────────── 拒止 ──────────────────────────

    @Test
    @DisplayName("资源不存在或已硬删：404 RESOURCE_NOT_FOUND（契约 §3.5）")
    void missingResourceIsNotFound() {
        UUID resourceId = UuidV7.generate();
        when(resourceMapper.selectById(resourceId)).thenReturn(null);

        CatalogException e = assertThrows(CatalogException.class, () -> trash.softDelete(resourceId));

        assertEquals(CatalogException.Code.RESOURCE_NOT_FOUND, e.code());
        verify(resourceMapper, never()).updateById(any(ResourceEntity.class));
    }

    @Test
    @DisplayName("内容行缺失（外键决定的异常态）：告警并 500，不软删")
    void missingContentRowIsAnExplicitFailure() {
        UUID resourceId = UuidV7.generate();
        ResourceEntity ready = resource(resourceId, "READY");
        when(resourceMapper.selectById(resourceId)).thenReturn(ready);
        when(contentMapper.selectById(ready.getContentId())).thenReturn(null);

        CatalogException e = assertThrows(CatalogException.class, () -> trash.softDelete(resourceId));

        assertEquals(CatalogException.Code.INTERNAL_ERROR, e.code());
        verify(resourceMapper, never()).updateById(any(ResourceEntity.class));
    }

    @Test
    @DisplayName("状态不在可软删范围（06 §7 无 PENDING／FAILED → DELETED）：拒止而非悄悄改态")
    void nonReadyStatusIsRefused() {
        UUID resourceId = UuidV7.generate();
        ResourceEntity pending = resource(resourceId, "PENDING");
        when(resourceMapper.selectById(resourceId)).thenReturn(pending);
        when(contentMapper.selectById(pending.getContentId())).thenReturn(content(pending.getContentId()));

        CatalogException e = assertThrows(CatalogException.class, () -> trash.softDelete(resourceId));

        assertEquals(CatalogException.Code.INTERNAL_ERROR, e.code());
        verify(resourceMapper, never()).updateById(any(ResourceEntity.class));
    }

    // ────────────────────────── 夹具 ──────────────────────────

    private static ResourceEntity resource(UUID id, String status) {
        ResourceEntity resource = new ResourceEntity();
        resource.setId(id);
        resource.setName("软删单元测试.bin");
        resource.setSizeBytes(16L);
        resource.setMimeType("application/octet-stream");
        resource.setContentId(UuidV7.generate());
        resource.setTags("[]");
        resource.setStatus(status);
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
}
