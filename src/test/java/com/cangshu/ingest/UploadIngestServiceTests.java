package com.cangshu.ingest;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.cangshu.catalog.CatalogException;
import com.cangshu.config.CangshuProperties;
import com.cangshu.storage.FileStore;
import com.cangshu.storage.Sha256Digester;
import java.io.ByteArrayInputStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.HexFormat;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;
import org.springframework.util.unit.DataSize;

/** ingest 翻译层：上限→413、声明大小不符→422、正常路径返回流式摘要（不触碰数据库）。 */
class UploadIngestServiceTests {

    @TempDir
    Path tempDir;

    private UploadIngestService ingest;
    private CangshuProperties properties;

    @BeforeEach
    void setUp() {
        properties = new CangshuProperties();
        properties.setDataRoot(tempDir.resolve("data-root").toString());
        properties.getUpload().setMaxSize(DataSize.ofKilobytes(1));
        ingest = new UploadIngestService(new FileStore(properties), new Sha256Digester(), properties);
    }

    @Test
    void stageReturnsDigestAndSize() throws Exception {
        byte[] content = "ingest-stage".getBytes();
        StagedUpload staged = ingest.stage(new ByteArrayInputStream(content), (long) content.length);
        String expected = HexFormat.of().formatHex(
                java.security.MessageDigest.getInstance("SHA-256").digest(content));
        assertEquals("SHA-256", staged.algorithm());
        assertEquals(expected, staged.digest());
        assertEquals(content.length, staged.sizeBytes());
        assertTrue(Files.isRegularFile(staged.temp()));
        Files.deleteIfExists(staged.temp());
    }

    @Test
    void overLimitTranslatesTo413() {
        CatalogException exception = assertThrows(CatalogException.class,
                () -> ingest.stage(new ByteArrayInputStream(new byte[2048]), null));
        assertEquals(CatalogException.Code.PAYLOAD_TOO_LARGE, exception.code());
        assertTrue(exception.getMessage().contains("上限"));
    }

    @Test
    void declaredSizeMismatchTranslatesTo422AndCleansTemp() throws Exception {
        byte[] content = "declared-mismatch".getBytes();
        CatalogException exception = assertThrows(CatalogException.class,
                () -> ingest.stage(new ByteArrayInputStream(content), (long) (content.length + 5)));
        assertEquals(CatalogException.Code.HASH_MISMATCH, exception.code());
        try (var list = Files.list(tempDir.resolve("data-root").resolve("tmp"))) {
            assertEquals(0, list.count(), "422 路径不得残留临时文件");
        }
    }
}
