package com.cangshu.storage;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.cangshu.config.CangshuProperties;
import java.io.ByteArrayInputStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.HexFormat;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;
import org.springframework.util.unit.DataSize;

/** 内容寻址字节层：流式摘要、存储键形状、移动不覆盖、逐字节比较、上限中止（04 §3／§4）。 */
class FileStoreTests {

    @TempDir
    Path tempDir;

    private FileStore files;

    @BeforeEach
    void setUp() {
        CangshuProperties properties = new CangshuProperties();
        properties.setDataRoot(tempDir.resolve("data-root").toString());
        files = new FileStore(properties);
    }

    private FileStore.Staged stage(byte[] content, long maxBytes) throws Exception {
        return files.stage(new ByteArrayInputStream(content), maxBytes, new Sha256Digester());
    }

    @Test
    void stageComputesSha256WhileStreaming() throws Exception {
        byte[] content = "仓鼠内容寻址字节层测试".getBytes();
        FileStore.Staged staged = stage(content, -1);
        assertEquals("SHA-256", staged.canonicalAlgorithm());
        assertEquals(content.length, staged.sizeBytes());
        String expected = HexFormat.of().formatHex(
                java.security.MessageDigest.getInstance("SHA-256").digest(content));
        assertEquals(expected, staged.digest());
        assertTrue(Files.isRegularFile(staged.temp()));
    }

    @Test
    void storageKeyUsesTwoLevelShardingUnderSha256Namespace() {
        String digest = "abcdef0123456789".repeat(4);
        String key = files.storageKey("SHA-256", digest);
        assertEquals("sha256/ab/cd/" + digest, key, "ab＝摘要第1–2位，cd＝第3–4位");
    }

    @Test
    void moveIntoPlacesBytesAndNeverOverwrites() throws Exception {
        byte[] content = "move-me".getBytes();
        FileStore.Staged staged = stage(content, -1);
        String key = files.storageKey("SHA-256", staged.digest());
        assertEquals(FileStore.MoveOutcome.MOVED, files.moveInto(staged.temp(), key));
        assertEquals(content.length, Files.size(files.blobPath(key)));
        assertFalse(Files.exists(staged.temp()));

        // 第二份同键临时文件：目标已存在 → 不覆盖
        FileStore.Staged second = stage(content, -1);
        assertEquals(FileStore.MoveOutcome.TARGET_EXISTS, files.moveInto(second.temp(), key));
        assertTrue(Files.isRegularFile(second.temp()), "未覆盖时临时文件保留由调用方处置");
        files.deleteTemp(second.temp());
    }

    @Test
    void sameBytesDetectsEqualityAndDifference() throws Exception {
        FileStore.Staged first = stage("same-bytes".getBytes(), -1);
        String key = files.storageKey("SHA-256", first.digest());
        files.moveInto(first.temp(), key);

        FileStore.Staged same = stage("same-bytes".getBytes(), -1);
        assertTrue(files.sameBytes(same.temp(), key));
        files.deleteTemp(same.temp());

        FileStore.Staged other = stage("other-bytes-and-length".getBytes(), -1);
        assertFalse(files.sameBytes(other.temp(), key));
        files.deleteTemp(other.temp());
    }

    @Test
    void limitExceededAbortsAndCleansTemp() {
        assertThrows(StorageLimitExceededException.class,
                () -> stage("0123456789".repeat(100).getBytes(), 100));
        try (var list = Files.list(tempDir.resolve("data-root").resolve("tmp"))) {
            assertEquals(0, list.count(), "中止后不得残留临时文件");
        } catch (Exception e) {
            throw new RuntimeException(e);
        }
    }

    @Test
    void blobPathRejectsIllegalKeys() {
        assertThrows(IllegalArgumentException.class, () -> files.blobPath("../escape"));
        assertThrows(IllegalArgumentException.class, () -> files.blobPath("sha256/ab"));
        assertThrows(IllegalArgumentException.class, () -> files.blobPath(null));
    }

    @Test
    void openAndBlobSizeServeContentBytes() throws Exception {
        byte[] content = "下载路径：open 与 blobSize 原语（任务 5）".getBytes(java.nio.charset.StandardCharsets.UTF_8);
        FileStore.Staged staged = stage(content, -1);
        String key = files.storageKey("SHA-256", staged.digest());
        files.moveInto(staged.temp(), key);

        assertEquals(content.length, files.blobSize(key), "blobSize＝内容字节大小");
        try (java.io.InputStream in = files.open(key)) {
            assertTrue(java.util.Arrays.equals(content, in.readAllBytes()), "open 返回完整只读流");
        }
    }

    @Test
    void openAndBlobSizeRejectMissingBlobAndIllegalKeys() throws Exception {
        String key = files.storageKey("SHA-256", "ab".repeat(32));
        assertThrows(java.nio.file.NoSuchFileException.class, () -> files.blobSize(key),
                "缺失字节显式失败（不得返回空流）");
        assertThrows(java.nio.file.NoSuchFileException.class, () -> files.open(key));
        assertThrows(IllegalArgumentException.class, () -> files.open("../../escape"));
    }
}
