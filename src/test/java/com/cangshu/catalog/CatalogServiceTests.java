package com.cangshu.catalog;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotEquals;
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

import com.cangshu.catalog.entity.ContentConflictEntity;
import com.cangshu.catalog.entity.ContentEntity;
import com.cangshu.catalog.entity.LocationEntity;
import com.cangshu.catalog.entity.ResourceEntity;
import com.cangshu.catalog.mapper.ContentConflictMapper;
import com.cangshu.catalog.mapper.ContentMapper;
import com.cangshu.catalog.mapper.LocationMapper;
import com.cangshu.catalog.mapper.ResourceMapper;
import com.cangshu.config.CangshuProperties;
import com.cangshu.ingest.StagedUpload;
import com.cangshu.storage.FileStore;
import com.cangshu.storage.LockTimeoutException;
import com.cangshu.storage.SegmentLockManager;
import com.cangshu.storage.Sha256Digester;
import java.io.ByteArrayInputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.HexFormat;
import java.util.List;
import java.util.UUID;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;
import org.mockito.ArgumentCaptor;
import org.springframework.dao.DuplicateKeyException;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.TransactionDefinition;
import org.springframework.transaction.TransactionStatus;
import org.springframework.transaction.support.SimpleTransactionStatus;

/**
 * 上传写入协议单元测试（catalog，任务 3；04-架构与计划 §4 七分支）。
 *
 * <p>本类补的是 HTTP 集成测试覆盖不到的分支与守卫：同一摘要多条异常记录、位置记录数异常、
 * 既有内容行而字节缺失、取锁超时、并发重试预算，以及「冲突必留审计、原行原字节不动」的断言。
 * mapper 用 Mockito 替身，字节层与分段锁用真实实现（{@code @TempDir} 落盘），
 * 事务用直通管理器（替身 mapper 不需要真实事务）。
 */
class CatalogServiceTests {

    private static final byte[] BYTES = "仓鼠上传写入协议单元测试：分支与守卫".getBytes(StandardCharsets.UTF_8);

    @TempDir
    Path tempDir;

    private FileStore files;
    private SegmentLockManager locks;
    private ContentMapper contentMapper;
    private ResourceMapper resourceMapper;
    private LocationMapper locationMapper;
    private ContentConflictMapper conflictMapper;
    private CatalogService catalog;

    @BeforeEach
    void setUp() {
        CangshuProperties properties = new CangshuProperties();
        properties.setDataRoot(tempDir.resolve("data-root").toString());
        files = new FileStore(properties);
        locks = new SegmentLockManager();
        contentMapper = mock(ContentMapper.class);
        resourceMapper = mock(ResourceMapper.class);
        locationMapper = mock(LocationMapper.class);
        conflictMapper = mock(ContentConflictMapper.class);
        catalog = new CatalogService(files, locks, contentMapper, resourceMapper, locationMapper,
                conflictMapper, new PassthroughTransactionManager());
    }

    // ────────────────────────── 夹具 ──────────────────────────

    /** 直通事务管理器：替身 mapper 不产生真实 SQL，事务边界只需把回调跑一遍。 */
    static final class PassthroughTransactionManager implements PlatformTransactionManager {

        @Override
        public TransactionStatus getTransaction(TransactionDefinition definition) {
            return new SimpleTransactionStatus();
        }

        @Override
        public void commit(TransactionStatus status) {
        }

        @Override
        public void rollback(TransactionStatus status) {
        }
    }

    private StagedUpload staged(byte[] bytes) throws Exception {
        FileStore.Staged staged = files.stage(new ByteArrayInputStream(bytes), -1, new Sha256Digester());
        return new StagedUpload(staged.temp(), staged.canonicalAlgorithm(), staged.digest(), staged.sizeBytes());
    }

    private String storageKeyOf(String digest) {
        return files.storageKey("SHA-256", digest);
    }

    private void givenExistingContentRows(List<ContentEntity> rows) {
        when(contentMapper.selectList(any())).thenReturn(rows);
    }

    private ContentEntity existingContent(long sizeBytes) {
        ContentEntity content = new ContentEntity();
        content.setId(UUID.randomUUID());
        content.setHashAlgorithm("SHA-256");
        content.setDigest("ab".repeat(32));
        content.setSizeBytes(sizeBytes);
        content.setStatus("READY");
        return content;
    }

    private void givenLocations(String... storageKeys) {
        List<LocationEntity> locations = java.util.Arrays.stream(storageKeys).map(key -> {
            LocationEntity location = new LocationEntity();
            location.setId(UUID.randomUUID());
            location.setStorageBackend("filesystem");
            location.setStorageKey(key);
            return location;
        }).toList();
        when(locationMapper.selectList(any())).thenReturn(locations);
    }

    /** 在数据根的内容地址上写入一份字节（模拟既有物理内容）。 */
    private Path writeBlob(String storageKey, byte[] bytes) throws Exception {
        Path blob = files.blobPath(storageKey);
        Files.createDirectories(blob.getParent());
        Files.write(blob, bytes);
        return blob;
    }

    private long tempFileCount() throws Exception {
        Path tmp = files.tmpDir();
        if (!Files.isDirectory(tmp)) {
            return 0L;
        }
        try (var list = Files.list(tmp)) {
            return list.count();
        }
    }

    private ContentConflictEntity capturedAudit() {
        ArgumentCaptor<ContentConflictEntity> captor = ArgumentCaptor.forClass(ContentConflictEntity.class);
        verify(conflictMapper, times(1)).insert(captor.capture());
        return captor.getValue();
    }

    // ────────────────────────── 分支 A：新建 ──────────────────────────

    @Test
    @DisplayName("A 新建：校验后原子移动，插内容＋位置＋资源三行，不复用")
    void createNewMovesBytesAndInsertsThreeRows() throws Exception {
        StagedUpload staged = staged(BYTES);
        givenExistingContentRows(List.of());

        CatalogService.UploadResult result = catalog.upload(staged, "首次上传.bin", "application/octet-stream");

        assertFalse(result.deduplicated(), "A 分支本次新建物理内容");
        assertNotNull(result.resourceId());
        assertNotNull(result.contentId());
        assertEquals("首次上传.bin", result.name());
        assertEquals(BYTES.length, result.sizeBytes());

        String storageKey = storageKeyOf(result.digest());
        assertEquals("sha256/" + result.digest().substring(0, 2) + "/"
                + result.digest().substring(2, 4) + "/" + result.digest(), storageKey, "相对存储键形状");
        assertTrue(Files.isRegularFile(files.blobPath(storageKey)), "字节已落到内容地址");
        assertFalse(Files.exists(staged.temp()), "A 分支临时文件已被移动");

        ArgumentCaptor<ContentEntity> content = ArgumentCaptor.forClass(ContentEntity.class);
        verify(contentMapper, times(1)).insert(content.capture());
        assertEquals("SHA-256", content.getValue().getHashAlgorithm(), "库内规范值");
        assertEquals(result.digest(), content.getValue().getDigest(), "库内摘要小写");
        assertEquals("READY", content.getValue().getStatus());

        verify(locationMapper, times(1)).insert(any(LocationEntity.class));
        verify(resourceMapper, times(1)).insert(any(ResourceEntity.class));
        verify(conflictMapper, never()).insert(any(ContentConflictEntity.class));
        assertEquals(0L, tempFileCount(), "成功路径不留临时文件");
    }

    // ────────────────────────── 分支 B：命中复用 ──────────────────────────

    @Test
    @DisplayName("B 命中复用：不重写字节、只插资源行，deduplicated=true")
    void existingContentWithIdenticalBytesReusesWithoutRewritingBytes() throws Exception {
        byte[] first = "B 分支：同内容再次上传".getBytes(StandardCharsets.UTF_8);
        FileStore.Staged seeded = files.stage(new ByteArrayInputStream(first), -1, new Sha256Digester());
        String storageKey = storageKeyOf(seeded.digest());
        files.moveInto(seeded.temp(), storageKey);
        String blobBefore = files.sha256Hex(files.blobPath(storageKey));

        ContentEntity existing = existingContent(first.length);
        existing.setDigest(seeded.digest());
        givenExistingContentRows(List.of(existing));
        givenLocations(storageKey);

        StagedUpload staged = staged(first);
        CatalogService.UploadResult result = catalog.upload(staged, "重复上传.bin", "application/octet-stream");

        assertTrue(result.deduplicated(), "命中同内容 → 复用既有存储");
        assertEquals(existing.getId(), result.contentId(), "contentId 指向既有内容");
        verify(contentMapper, never()).insert(any(ContentEntity.class));
        verify(locationMapper, never()).insert(any(LocationEntity.class));
        verify(resourceMapper, times(1)).insert(any(ResourceEntity.class));
        verify(conflictMapper, never()).insert(any(ContentConflictEntity.class));
        assertEquals(blobBefore, files.sha256Hex(files.blobPath(storageKey)), "不重写既有字节");
        assertFalse(Files.exists(staged.temp()), "复用路径清理临时文件");
    }

    // ────────────────────────── 分支 D：大小冲突 ──────────────────────────

    @Test
    @DisplayName("D 大小冲突：不逐字节比较、写 SIZE_MISMATCH 审计、409、原行原字节不动")
    void sizeMismatchWritesAuditAndLeavesExistingRowAndBytesUntouched() throws Exception {
        byte[] existingBytes = "既有内容较长".getBytes(StandardCharsets.UTF_8);
        byte[] incomingBytes = "短".getBytes(StandardCharsets.UTF_8);
        FileStore.Staged seeded = files.stage(new ByteArrayInputStream(existingBytes), -1, new Sha256Digester());
        String storageKey = storageKeyOf(seeded.digest());
        files.moveInto(seeded.temp(), storageKey);
        String blobBefore = files.sha256Hex(files.blobPath(storageKey));

        ContentEntity existing = existingContent(existingBytes.length);
        existing.setDigest(seeded.digest());
        givenExistingContentRows(List.of(existing));
        givenLocations(storageKey);

        StagedUpload staged = staged(incomingBytes);
        CatalogException exception = assertThrows(CatalogException.class,
                () -> catalog.upload(staged, "来者.bin", "application/octet-stream"));

        assertEquals(CatalogException.Code.CONTENT_CONFLICT, exception.code());
        assertEquals(409, exception.code().httpStatus());
        assertEquals("SIZE_MISMATCH", exception.reason(), "冲突响应 reason 必填（I1）");

        ContentConflictEntity audit = capturedAudit();
        assertEquals("SIZE_MISMATCH", audit.getReason());
        assertEquals(existing.getId(), audit.getExistingContentId());
        assertEquals(existingBytes.length, audit.getExistingSizeBytes());
        assertEquals(incomingBytes.length, audit.getIncomingSizeBytes());
        assertNotNull(audit.getIncomingStorageKey(), "incoming_storage_key 必有（DEC-I5）");

        verify(resourceMapper, never()).insert(any(ResourceEntity.class));
        assertEquals(blobBefore, files.sha256Hex(files.blobPath(storageKey)), "原字节不动");
        assertFalse(Files.exists(staged.temp()), "冲突路径清理临时文件");
    }

    // ────────────────────────── 分支 E：字节冲突 ──────────────────────────

    @Test
    @DisplayName("E 字节冲突：同大小不同字节 → BYTE_MISMATCH 审计、409、原字节不动")
    void byteMismatchWritesAuditAndRefusesWrite() throws Exception {
        byte[] existingBytes = "BYTE-MISMATCH 同大小 A".getBytes(StandardCharsets.UTF_8);
        byte[] incomingBytes = "BYTE-MISMATCH 同大小 B".getBytes(StandardCharsets.UTF_8);
        assertEquals(existingBytes.length, incomingBytes.length, "前置：同大小");

        FileStore.Staged seeded = files.stage(new ByteArrayInputStream(existingBytes), -1, new Sha256Digester());
        String storageKey = storageKeyOf(seeded.digest());
        files.moveInto(seeded.temp(), storageKey);
        String blobBefore = files.sha256Hex(files.blobPath(storageKey));

        ContentEntity existing = existingContent(existingBytes.length);
        existing.setDigest(seeded.digest());
        givenExistingContentRows(List.of(existing));
        givenLocations(storageKey);

        StagedUpload staged = staged(incomingBytes);
        CatalogException exception = assertThrows(CatalogException.class,
                () -> catalog.upload(staged, "来者.bin", "application/octet-stream"));

        assertEquals("BYTE_MISMATCH", exception.reason());
        ContentConflictEntity audit = capturedAudit();
        assertEquals("BYTE_MISMATCH", audit.getReason());
        assertEquals(storageKey, audit.getExistingStorageKey(), "既有侧键确实存在时如实填写");
        assertEquals(blobBefore, files.sha256Hex(files.blobPath(storageKey)), "原字节不动");
        verify(contentMapper, never()).insert(any(ContentEntity.class));
    }

    // ────────────────────────── 分支 F：目标键被占 ──────────────────────────

    @Test
    @DisplayName("F 目标键被占且字节相同：幂等补齐索引行，不覆盖既有字节")
    void targetOccupiedWithIdenticalBytesReconcilesIndexRows() throws Exception {
        byte[] content = "F 分支：字节已在、行已丢".getBytes(StandardCharsets.UTF_8);
        FileStore.Staged seeded = files.stage(new ByteArrayInputStream(content), -1, new Sha256Digester());
        String storageKey = storageKeyOf(seeded.digest());
        files.moveInto(seeded.temp(), storageKey);
        String blobBefore = files.sha256Hex(files.blobPath(storageKey));

        givenExistingContentRows(List.of());

        StagedUpload staged = staged(content);
        CatalogService.UploadResult result = catalog.upload(staged, "补齐行.bin", "application/octet-stream");

        assertTrue(result.deduplicated(), "字节相同 → 幂等补齐并复用");
        verify(contentMapper, times(1)).insert(any(ContentEntity.class));
        verify(locationMapper, times(1)).insert(any(LocationEntity.class));
        verify(resourceMapper, times(1)).insert(any(ResourceEntity.class));
        verify(conflictMapper, never()).insert(any(ContentConflictEntity.class));
        assertEquals(blobBefore, files.sha256Hex(files.blobPath(storageKey)), "补齐不覆盖既有字节");
        assertEquals(0L, tempFileCount(), "F 补齐路径显式清理临时字节");
    }

    @Test
    @DisplayName("F 目标键被占且字节不同：TARGET_PATH_EXISTS 审计 ＋ 409，不覆盖不接管")
    void targetOccupiedWithDifferentBytesReturnsTargetPathExists() throws Exception {
        byte[] existingBytes = "F 冲突：既有字节".getBytes(StandardCharsets.UTF_8);
        byte[] incomingBytes = "F 冲突：来者字节".getBytes(StandardCharsets.UTF_8);
        assertEquals(existingBytes.length, incomingBytes.length, "前置：同大小");

        // 内容地址上先有一份字节；库内无对应内容行（行已丢）
        String digest = HexFormat.of().formatHex(
                java.security.MessageDigest.getInstance("SHA-256").digest(incomingBytes));
        String storageKey = storageKeyOf(digest);
        writeBlob(storageKey, existingBytes);
        givenExistingContentRows(List.of());

        StagedUpload staged = staged(incomingBytes);
        CatalogException exception = assertThrows(CatalogException.class,
                () -> catalog.upload(staged, "来者.bin", "application/octet-stream"));

        assertEquals("TARGET_PATH_EXISTS", exception.reason());
        ContentConflictEntity audit = capturedAudit();
        assertEquals("TARGET_PATH_EXISTS", audit.getReason());
        assertNull(audit.getExistingContentId(), "无可合法复用内容 → 不填伪 ID（DEC-I5）");
        assertNotNull(audit.getIncomingStorageKey());
        assertEquals(HexFormat.of().formatHex(
                        java.security.MessageDigest.getInstance("SHA-256").digest(existingBytes)),
                files.sha256Hex(files.blobPath(storageKey)), "字节未被覆盖");
    }

    // ────────────────────────── 数据损坏守卫 ──────────────────────────

    @Test
    @DisplayName("同一「算法＋摘要」多条内容记录：拒绝写入并告警，不任选一条")
    void multipleContentRowsForSameDigestRefuseWrite() throws Exception {
        StagedUpload staged = staged(BYTES);
        givenExistingContentRows(List.of(existingContent(BYTES.length), existingContent(BYTES.length)));

        CatalogException exception = assertThrows(CatalogException.class,
                () -> catalog.upload(staged, "多行.bin", "application/octet-stream"));

        assertEquals(CatalogException.Code.INTERNAL_ERROR, exception.code());
        assertTrue(exception.getMessage().contains("多条"), "必须拒绝写入并告警：" + exception.getMessage());
        verify(contentMapper, never()).insert(any(ContentEntity.class));
        verify(resourceMapper, never()).insert(any(ResourceEntity.class));
    }

    @Test
    @DisplayName("既有内容行在、字节缺失：拒绝复用判定并告警（缺失字节＝最高危）")
    void existingContentRowWithMissingBytesRefusesReuse() throws Exception {
        StagedUpload staged = staged(BYTES);
        ContentEntity existing = existingContent(BYTES.length);
        givenExistingContentRows(List.of(existing));
        givenLocations(storageKeyOf(existing.getDigest()));  // 键存在但盘上无文件

        CatalogException exception = assertThrows(CatalogException.class,
                () -> catalog.upload(staged, "字节缺失.bin", "application/octet-stream"));

        assertEquals(CatalogException.Code.INTERNAL_ERROR, exception.code());
        assertTrue(exception.getMessage().contains("字节缺失"), exception.getMessage());
        verify(resourceMapper, never()).insert(any(ResourceEntity.class));
    }

    @Test
    @DisplayName("上传侧位置记录数异常（非恰好一条）：拒绝写入并告警")
    void locationAnomalyOnUploadRefusesWrite() throws Exception {
        StagedUpload staged = staged(BYTES);
        ContentEntity existing = existingContent(BYTES.length);
        givenExistingContentRows(List.of(existing));
        givenLocations();  // 0 条位置记录

        CatalogException exception = assertThrows(CatalogException.class,
                () -> catalog.upload(staged, "位置异常.bin", "application/octet-stream"));

        assertEquals(CatalogException.Code.INTERNAL_ERROR, exception.code());
        assertTrue(exception.getMessage().contains("位置记录数异常"), exception.getMessage());
    }

    // ────────────────────────── 取锁与重试预算 ──────────────────────────

    @Test
    @DisplayName("等待分段锁超时 → 503 SERVICE_BUSY（明确可重试）并清理临时文件")
    void lockTimeoutTranslatesToServiceBusyAndCleansTemp() throws Exception {
        SegmentLockManager timedOut = new SegmentLockManager() {
            @Override
            public Handle acquire(String canonicalAlgorithm, String digest) {
                throw new LockTimeoutException(lockKey(canonicalAlgorithm, digest), "测试：模拟取锁超时");
            }
        };
        CatalogService service = new CatalogService(files, timedOut, contentMapper, resourceMapper,
                locationMapper, conflictMapper, new PassthroughTransactionManager());

        StagedUpload staged = staged(BYTES);
        CatalogException exception = assertThrows(CatalogException.class,
                () -> service.upload(staged, "被锁.bin", "application/octet-stream"));

        assertEquals(CatalogException.Code.SERVICE_BUSY, exception.code());
        assertEquals(503, exception.code().httpStatus());
        assertTrue(exception.getMessage().contains("请稍后重试"), "必须提示可重试：" + exception.getMessage());
        assertFalse(exception.getMessage().contains("损坏"), "不得提示数据损坏");
        assertFalse(Files.exists(staged.temp()), "取锁失败必须清理临时文件");
        assertEquals(0L, tempFileCount());
    }

    @Test
    @DisplayName("并发抢先（移动落空）重试 2 次后耗尽 → 500 INTERNAL_ERROR，共 3 次尝试")
    void concurrentRaceRetriesExactlyTwiceBeforeFailing() throws Exception {
        FileStore raced = mock(FileStore.class);
        when(raced.storageKey(any(), any())).thenReturn(storageKeyOf("ab".repeat(32)));
        when(raced.blobExists(any())).thenReturn(false);
        when(raced.moveInto(any(), any())).thenReturn(FileStore.MoveOutcome.TARGET_EXISTS);
        CatalogService service = new CatalogService(raced, locks, contentMapper, resourceMapper,
                locationMapper, conflictMapper, new PassthroughTransactionManager());

        StagedUpload staged = staged(BYTES);
        CatalogException exception = assertThrows(CatalogException.class,
                () -> service.upload(staged, "并发.bin", "application/octet-stream"));

        assertEquals(CatalogException.Code.INTERNAL_ERROR, exception.code());
        assertTrue(exception.getMessage().contains("并发重试次数耗尽"), exception.getMessage());
        verify(raced, times(3)).moveInto(any(), any());
        verify(raced, times(1)).deleteTemp(any());
        verify(contentMapper, never()).insert(any(ContentEntity.class));
    }

    // ────────────────────────── 缺陷复现（已修复） ──────────────────────────

    @Test
    @DisplayName("G 并发抢先（插入被唯一约束挡下）：重试重验字节后转复用，不误报冲突、不写不实审计")
    void gBranchRetryAfterSuccessfulMoveReusesInsteadOfReportingFalseConflict() throws Exception {
        StagedUpload staged = staged(BYTES);
        String digest = staged.digest();
        String storageKey = storageKeyOf(digest);

        // 第一轮：无内容行、无目标字节 → createNew 移动成功；插入内容行时被唯一约束挡下。
        // 第二轮：selectContentForUpdate 看到「抢先者」的行，且恰有一条位置记录。
        ContentEntity winner = existingContent(BYTES.length);
        winner.setDigest(digest);
        when(contentMapper.selectList(any())).thenReturn(List.of(), List.of(winner));
        givenLocations(storageKey);
        when(contentMapper.insert(any(ContentEntity.class))).thenThrow(new DuplicateKeyException("ug_content"));

        CatalogService.UploadResult result = catalog.upload(staged, "并发抢先.bin", "application/octet-stream");

        assertTrue(result.deduplicated(), "重试应转为复用（reused=true）");
        assertEquals(winner.getId(), result.contentId());
        verify(conflictMapper, never()).insert(any(ContentConflictEntity.class));
    }

    // ────────────────────────── 摘要归一化 ──────────────────────────

    @Test
    @DisplayName("库内摘要与存储键一律使用归一化后的小写摘要")
    void digestIsNormalizedToLowerCaseForIdentityAndStorageKey() throws Exception {
        StagedUpload staged = staged(BYTES);
        givenExistingContentRows(List.of());

        CatalogService.UploadResult result = catalog.upload(staged, "大小写.bin", "application/octet-stream");

        assertEquals(staged.digest().toLowerCase(), result.digest());
        ArgumentCaptor<ContentEntity> content = ArgumentCaptor.forClass(ContentEntity.class);
        verify(contentMapper, times(1)).insert(content.capture());
        assertEquals(content.getValue().getDigest(), content.getValue().getDigest().toLowerCase(),
                "库内摘要必须小写 64 位十六进制");
        assertNotEquals("", content.getValue().getDigest());
    }
}
