package com.cangshu.catalog;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.Mockito.when;

import com.cangshu.catalog.entity.ContentEntity;
import com.cangshu.catalog.entity.LocationEntity;
import com.cangshu.catalog.entity.ResourceEntity;
import com.cangshu.catalog.mapper.ContentMapper;
import com.cangshu.catalog.mapper.LocationMapper;
import com.cangshu.catalog.mapper.ResourceMapper;
import com.cangshu.config.CangshuProperties;
import com.cangshu.storage.FileStore;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;
import java.util.UUID;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

/**
 * 下载解析单元测试（catalog，任务 5）：404 口径（不存在／软删）、内容身份守卫
 * （内容行缺失／非就绪／位置异常）、字节守卫（缺失／大小不符 → 拒绝下载，绝不返回空文件）。
 * mapper 用 Mockito 替身，字节层用真实 FileStore 落临时目录。
 */
class DownloadServiceTests {

    private static final byte[] BYTES = "下载解析单元测试：字节与元数据".getBytes(StandardCharsets.UTF_8);

    @TempDir
    Path tempDir;

    private ResourceMapper resourceMapper;
    private ContentMapper contentMapper;
    private LocationMapper locationMapper;
    private FileStore files;
    private DownloadService downloads;

    private final UUID resourceId = UUID.randomUUID();
    private final UUID contentId = UUID.randomUUID();
    private final String digest = "ab".repeat(32);
    private final String storageKey = "sha256/ab/ab/" + digest;

    @BeforeEach
    void setUp() throws Exception {
        resourceMapper = org.mockito.Mockito.mock(ResourceMapper.class);
        contentMapper = org.mockito.Mockito.mock(ContentMapper.class);
        locationMapper = org.mockito.Mockito.mock(LocationMapper.class);
        CangshuProperties properties = new CangshuProperties();
        properties.setDataRoot(tempDir.resolve("data-root").toString());
        files = new FileStore(properties);
        downloads = new DownloadService(resourceMapper, contentMapper, locationMapper, files);

        // 默认装配：就绪资源 → 就绪内容 → 恰一条位置记录 → 盘上字节与身份大小一致
        when(resourceMapper.selectById(resourceId)).thenReturn(readyResource("READY"));
        when(contentMapper.selectById(contentId)).thenReturn(readyContent());
        LocationEntity location = new LocationEntity();
        location.setId(UUID.randomUUID());
        location.setContentId(contentId);
        location.setStorageBackend("filesystem");
        location.setStorageKey(storageKey);
        when(locationMapper.selectList(org.mockito.ArgumentMatchers.any())).thenReturn(List.of(location));
        Path blob = tempDir.resolve("data-root").resolve(storageKey);
        Files.createDirectories(blob.getParent());
        Files.write(blob, BYTES);
    }

    private ResourceEntity readyResource(String status) {
        ResourceEntity resource = new ResourceEntity();
        resource.setId(resourceId);
        resource.setName("样本文件.bin");
        resource.setSizeBytes((long) BYTES.length);
        resource.setMimeType("application/octet-stream");
        resource.setContentId(contentId);
        resource.setStatus(status);
        return resource;
    }

    private ContentEntity readyContent() {
        ContentEntity content = new ContentEntity();
        content.setId(contentId);
        content.setHashAlgorithm("SHA-256");
        content.setDigest(digest);
        content.setSizeBytes((long) BYTES.length);
        content.setStatus("READY");
        return content;
    }

    @Test
    void openReturnsMetadataAndFullStream() throws Exception {
        DownloadService.DownloadPayload payload = downloads.open(resourceId);
        assertEquals(resourceId, payload.resourceId());
        assertEquals(contentId, payload.contentId());
        assertEquals("样本文件.bin", payload.name());
        assertEquals("application/octet-stream", payload.mimeType());
        assertEquals(BYTES.length, payload.sizeBytes());
        try (InputStream in = payload.stream()) {
            assertTrue(java.util.Arrays.equals(BYTES, in.readAllBytes()), "流内容与盘上字节一致");
        }
    }

    @Test
    void missingResourceMapsTo404() {
        when(resourceMapper.selectById(resourceId)).thenReturn(null);
        CatalogException exception = assertThrows(CatalogException.class, () -> downloads.open(resourceId));
        assertEquals(CatalogException.Code.RESOURCE_NOT_FOUND, exception.code());
    }

    @Test
    void softDeletedResourceMapsTo404() {
        // 回收站中的资源对普通下载不可见（与详情同口径；软删等价约束保证两个时间戳非空）
        when(resourceMapper.selectById(resourceId)).thenReturn(readyResource("DELETED"));
        CatalogException exception = assertThrows(CatalogException.class, () -> downloads.open(resourceId));
        assertEquals(CatalogException.Code.RESOURCE_NOT_FOUND, exception.code());
    }

    @Test
    void missingContentRowRefusesDownloadWithAlert() {
        when(contentMapper.selectById(contentId)).thenReturn(null);
        CatalogException exception = assertThrows(CatalogException.class, () -> downloads.open(resourceId));
        assertEquals(CatalogException.Code.INTERNAL_ERROR, exception.code());
        assertTrue(exception.getMessage().contains("拒绝下载"));
    }

    @Test
    void nonReadyContentRefusesDownloadWithAlert() {
        ContentEntity reclaiming = readyContent();
        reclaiming.setStatus("RECLAIMING");
        when(contentMapper.selectById(contentId)).thenReturn(reclaiming);
        assertEquals(CatalogException.Code.INTERNAL_ERROR,
                assertThrows(CatalogException.class, () -> downloads.open(resourceId)).code());
    }

    @Test
    void locationAnomalyRefusesDownload() {
        when(locationMapper.selectList(org.mockito.ArgumentMatchers.any())).thenReturn(List.of());
        assertEquals(CatalogException.Code.INTERNAL_ERROR,
                assertThrows(CatalogException.class, () -> downloads.open(resourceId)).code());
    }

    @Test
    void missingBytesRefuseDownloadInsteadOfEmptyFile() throws Exception {
        Files.delete(tempDir.resolve("data-root").resolve(storageKey));
        CatalogException exception = assertThrows(CatalogException.class, () -> downloads.open(resourceId));
        assertEquals(CatalogException.Code.INTERNAL_ERROR, exception.code());
        assertTrue(exception.getMessage().contains("字节缺失"), "缺失字节必须拒绝并告警（08 §4）");
    }

    @Test
    void sizeMismatchWithIdentityRefusesDownload() throws Exception {
        // 盘上字节被截断：大小与内容身份不符 → 拒绝下载并告警，不盲发
        try (var channel = java.nio.channels.FileChannel.open(
                tempDir.resolve("data-root").resolve(storageKey),
                java.nio.file.StandardOpenOption.WRITE)) {
            channel.truncate(4);
        }
        CatalogException exception = assertThrows(CatalogException.class, () -> downloads.open(resourceId));
        assertEquals(CatalogException.Code.INTERNAL_ERROR, exception.code());
        assertTrue(exception.getMessage().contains("与身份不符"));
        assertNotNull(exception);
    }
}
