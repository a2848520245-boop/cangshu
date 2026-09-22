package com.cangshu.storage;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.junit.jupiter.api.Assumptions.assumeTrue;

import com.cangshu.common.StagedUpload;
import com.cangshu.config.WriterGate;
import java.io.ByteArrayInputStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.HexFormat;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;
import org.springframework.util.unit.DataSize;

/** 内容寻址字节层：流式摘要、存储键形状、移动不覆盖、逐字节比较、上限中止（04 §3／§4）。 */
class FileStoreTests {

    /** 隔离键判定用的门协议锁文件名：与装配层注入 {@code FileStore} 的是同一个登记常量。 */
    private static final String LOCK_NAME = WriterGate.LOCK_FILE_NAME;

    @TempDir
    Path tempDir;

    private FileStore files;

    @BeforeEach
    void setUp() {
        files = new FileStore(tempDir.resolve("data-root"), LOCK_NAME);
    }

    private StagedUpload stage(byte[] content, long maxBytes) throws Exception {
        return files.stage(new ByteArrayInputStream(content), maxBytes, new Sha256Digester());
    }

    @Test
    void stageComputesSha256WhileStreaming() throws Exception {
        byte[] content = "仓鼠内容寻址字节层测试".getBytes();
        StagedUpload staged = stage(content, -1);
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
        StagedUpload staged = stage(content, -1);
        String key = files.storageKey("SHA-256", staged.digest());
        assertEquals(FileStore.MoveOutcome.MOVED, files.moveInto(staged.temp(), key));
        assertEquals(content.length, Files.size(files.blobPath(key)));
        assertFalse(Files.exists(staged.temp()));

        // 第二份同键临时文件：目标已存在 → 不覆盖
        StagedUpload second = stage(content, -1);
        assertEquals(FileStore.MoveOutcome.TARGET_EXISTS, files.moveInto(second.temp(), key));
        assertTrue(Files.isRegularFile(second.temp()), "未覆盖时临时文件保留由调用方处置");
        files.deleteTemp(second.temp());
    }

    @Test
    void sameBytesDetectsEqualityAndDifference() throws Exception {
        StagedUpload first = stage("same-bytes".getBytes(), -1);
        String key = files.storageKey("SHA-256", first.digest());
        files.moveInto(first.temp(), key);

        StagedUpload same = stage("same-bytes".getBytes(), -1);
        assertTrue(files.sameBytes(same.temp(), key));
        files.deleteTemp(same.temp());

        StagedUpload other = stage("other-bytes-and-length".getBytes(), -1);
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
        StagedUpload staged = stage(content, -1);
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

    // ───────────────────── 隔离移动 moveToOrphan 加固（P0-3 收尾补丁 P6）─────────────────────

    @Test
    @DisplayName("隔离移动：门锁文件的写法变体一律被拒，门锁文件原样留存")
    void moveToOrphanRejectsGateLockFileVariants() throws Exception {
        Path root = Files.createDirectories(files.dataRoot());
        Path lockFile = root.resolve(LOCK_NAME);
        Files.writeString(lockFile, "门锁内容");

        String[] variants = {
                LOCK_NAME, "./" + LOCK_NAME, "sub/../" + LOCK_NAME,
                LOCK_NAME + ".", LOCK_NAME + " ", LOCK_NAME.toUpperCase(java.util.Locale.ROOT)
        };
        for (String variant : variants) {
            assertThrows(IllegalArgumentException.class, () -> files.moveToOrphan(variant),
                    "门锁文件的写法变体必须被拒：" + variant);
        }
        assertTrue(Files.isRegularFile(lockFile), "门锁文件必须留在原路径（挪走＝门的互斥失效）");
        assertEquals("门锁内容", Files.readString(lockFile), "门锁文件的内容与位置都不得改变");
        assertFalse(Files.exists(root.resolve("orphan").resolve(LOCK_NAME)), "门锁文件不得出现在隔离区");
    }

    @Test
    @DisplayName("隔离移动：普通文件键正常隔离；源缺失与目标已存在各按其语义返回")
    void moveToOrphanMovesRegularFilesAndNeverOverwrites() throws Exception {
        String key = files.storageKey("SHA-256", "ab".repeat(32));
        Path blob = files.blobPath(key);
        Files.createDirectories(blob.getParent());
        Files.writeString(blob, "孤儿字节");

        assertEquals(FileStore.OrphanOutcome.MOVED, files.moveToOrphan(key), "普通文件键应当被隔离");
        assertEquals("孤儿字节", Files.readString(files.orphanPath(key)));
        assertFalse(Files.exists(blob), "隔离后原内容地址不再有字节");
        assertEquals(FileStore.OrphanOutcome.SOURCE_MISSING, files.moveToOrphan(key), "源已不在原处：无移动");

        Path legacy = Files.writeString(files.dataRoot().resolve("legacy.bin"), "源");
        Path legacyOrphan = files.dataRoot().resolve("orphan").resolve("legacy.bin");
        Files.createDirectories(legacyOrphan.getParent());
        Files.writeString(legacyOrphan, "隔离区里的既有字节");
        assertEquals(FileStore.OrphanOutcome.TARGET_EXISTS, files.moveToOrphan("legacy.bin"), "目标已存在即放弃移动");
        assertEquals("源", Files.readString(legacy), "源字节不动");
        assertEquals("隔离区里的既有字节", Files.readString(legacyOrphan), "隔离区既有字节不被覆盖");
    }

    @Test
    @DisplayName("隔离移动：目录键不是可隔离的字节对象（拒绝且原物不动）")
    void moveToOrphanRejectsDirectoryKeys() throws Exception {
        Path root = Files.createDirectories(files.dataRoot());
        Path inner = Files.createDirectories(root.resolve("legacy-dir").resolve("inner"));
        Files.writeString(inner.resolve("note.txt"), "目录里的文件");

        assertThrows(IllegalArgumentException.class, () -> files.moveToOrphan("legacy-dir"),
                "目录键必须被拒（隔离只搬普通文件）");
        assertTrue(Files.isDirectory(inner), "目录原物不动");
        assertFalse(Files.exists(root.resolve("orphan").resolve("legacy-dir")), "不得在隔离区留下目录副本");
    }

    @Test
    @DisplayName("隔离移动：数据根内的目录联接指向根外时被拒（NOFOLLOW 的 realpath 不穿透联接）")
    void moveToOrphanRejectsDirectoryLinkLeavingDataRoot() throws Exception {
        Path root = Files.createDirectories(files.dataRoot());
        Path lockFile = root.resolve(LOCK_NAME);
        Files.writeString(lockFile, "门锁内容");
        Path outside = Files.createDirectories(tempDir.resolve("outside"));
        Path leaked = Files.writeString(outside.resolve("leak.bin"), "根外字节");
        Path link = root.resolve("junction");
        assumeTrue(createDirectoryLink(link, outside),
                "本平台建不出目录联接／目录符号链接，跳过（Windows 用 mklink /J，无需管理员）");

        assertThrows(IllegalArgumentException.class, () -> files.moveToOrphan("junction/leak.bin"),
                "联接把字节指向数据根之外，必须拒绝隔离");
        assertEquals("根外字节", Files.readString(leaked), "根外字节不得被移动或改写");
        assertEquals("门锁内容", Files.readString(lockFile), "门锁文件原样留存");
        assertFalse(Files.exists(root.resolve("orphan").resolve("junction")), "隔离区不得出现该联接下的内容");
    }

    /**
     * 建一个「数据根内的目录联接 → 根外目录」：Windows 用 {@code mklink /J}（目录联接，无需管理员），
     * 其它平台退化为目录符号链接。建不出来时返回 false，由调用方 {@code assumeTrue} 跳过。
     */
    private static boolean createDirectoryLink(Path link, Path target) {
        String osName = System.getProperty("os.name", "").toLowerCase(java.util.Locale.ROOT);
        try {
            if (osName.startsWith("windows")) {
                Process process = new ProcessBuilder("cmd.exe", "/c", "mklink", "/J",
                        link.toString(), target.toString()).redirectErrorStream(true).start();
                return process.waitFor() == 0 && Files.isDirectory(link);
            }
            Files.createSymbolicLink(link, target);
            return Files.isDirectory(link);
        } catch (java.io.IOException e) {
            return false;
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            return false;
        }
    }
}
