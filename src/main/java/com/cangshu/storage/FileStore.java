package com.cangshu.storage;

import com.cangshu.config.CangshuProperties;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.nio.file.AtomicMoveNotSupportedException;
import java.nio.file.FileAlreadyExistsException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.security.MessageDigest;
import java.util.HexFormat;
import java.util.regex.Pattern;
import org.springframework.stereotype.Component;

/**
 * 内容寻址字节层（storage 模块；04-架构与计划 §1：不认识资源业务概念、不写数据库）。
 *
 * <p>物理存储键＝{@code sha256/ab/cd/<digest>}（ab＝摘要第 1–2 位、cd＝第 3–4 位；相对键，
 * 不含数据根前缀，06-数据契约 §5）。临时区 {@code <data-root>/tmp/} 与正式区同在数据根下
 * （同一文件系统，移动才成立）。业务层只使用相对存储键，路径解析只在 storage 内部。
 */
@Component
public class FileStore {

    /** 相对存储键的安全形状：小写字母数字首段 ＋ 两段两位十六进制 ＋ 64 位摘要。 */
    private static final Pattern STORAGE_KEY_PATTERN =
            Pattern.compile("[a-z0-9]+/[0-9a-f]{2}/[0-9a-f]{2}/[0-9a-f]{64}");

    private final Path dataRoot;
    private final Path tmpDir;

    public FileStore(CangshuProperties properties) {
        this.dataRoot = Path.of(properties.getDataRoot()).toAbsolutePath().normalize();
        this.tmpDir = this.dataRoot.resolve("tmp");
    }

    /** 流式落盘结果：临时文件 ＋ 已归一算法 ＋ 边写边算的摘要 ＋ 实际接收字节数。 */
    public record Staged(Path temp, String canonicalAlgorithm, String digest, long sizeBytes) {
    }

    /**
     * 上传第一步：流式落临时文件并同时计算摘要，不把完整文件读入内存（REQ-M1-02）。
     *
     * <p>超过 {@code maxBytes} 立即中止并清理临时文件；目录懒创建（启动门属任务 29，
     * 本任务无启动门，但保持「首次写盘才建目录」的最小副作用原则）。
     */
    public Staged stage(InputStream in, long maxBytes, Digestor digestor) throws IOException {
        Files.createDirectories(tmpDir);
        Path temp = Files.createTempFile(tmpDir, "upload-", ".tmp");
        MessageDigest digest = digestor.create();
        long total = 0L;
        try (OutputStream out = Files.newOutputStream(temp)) {
            byte[] buffer = new byte[64 * 1024];
            int read;
            while ((read = in.read(buffer)) > 0) {
                if (maxBytes >= 0 && total + read > maxBytes) {
                    throw new StorageLimitExceededException(maxBytes, total + read);
                }
                total += read;
                digest.update(buffer, 0, read);
                out.write(buffer, 0, read);
            }
        } catch (IOException | RuntimeException e) {
            Files.deleteIfExists(temp);
            throw e;
        }
        return new Staged(temp, digestor.canonicalAlgorithm(), HexFormat.of().formatHex(digest.digest()), total);
    }

    /** 相对存储键：命名空间 ＋ 摘要前 4 位分两段 ＋ 摘要（04 §3）。 */
    public String storageKey(String canonicalAlgorithm, String digest) {
        String namespace = Algorithms.storageNamespace(canonicalAlgorithm);
        return namespace + "/" + digest.substring(0, 2) + "/" + digest.substring(2, 4) + "/" + digest;
    }

    /** 相对存储键 → 绝对路径（只允许本类与测试经此解析；拒绝形状不符的键）。 */
    public Path blobPath(String storageKey) {
        if (storageKey == null || !STORAGE_KEY_PATTERN.matcher(storageKey).matches()) {
            throw new IllegalArgumentException("非法存储键：" + storageKey);
        }
        return dataRoot.resolve(storageKey);
    }

    public boolean blobExists(String storageKey) {
        return storageKey != null && STORAGE_KEY_PATTERN.matcher(storageKey).matches()
                && Files.isRegularFile(dataRoot.resolve(storageKey));
    }

    /** 内容字节大小（下载校验与 Content-Length 用）；文件缺失抛 {@link NoSuchFileException}。 */
    public long blobSize(String storageKey) throws IOException {
        return Files.size(blobPath(storageKey));
    }

    /**
     * 打开内容字节的只读流（下载路径，任务 5；调用方负责关闭流）。
     * 键形状不合法抛 {@link IllegalArgumentException}；文件缺失抛 {@link NoSuchFileException}，
     * 由业务层翻译为「拒绝下载并告警」（08-验收规范 §4：缺失字节不得返回空文件）。
     */
    public InputStream open(String storageKey) throws IOException {
        return Files.newInputStream(blobPath(storageKey));
    }

    /** 逐字节比较（DEC-T4 第二步）；任一侧缺失或大小不同 → false（大小比较由调用方先行）。 */
    public boolean sameBytes(Path temp, String storageKey) throws IOException {
        Path blob = blobPath(storageKey);
        if (!Files.isRegularFile(blob) || !Files.isRegularFile(temp)) {
            return false;
        }
        if (Files.size(temp) != Files.size(blob)) {
            return false;
        }
        return Files.mismatch(temp, blob) == -1L;
    }

    public enum MoveOutcome {
        /** 本次调用把临时文件移入内容地址。 */
        MOVED,
        /** 目标已存在：未覆盖、未改写（绝不覆盖式替换；临时文件由调用方处置）。 */
        TARGET_EXISTS
    }

    /**
     * 校验全部通过后才调用：把临时文件原子移入内容地址，绝不覆盖（DEC-T4／04 §4）。
     * 前置存在性检查 ＋ ATOMIC_MOVE（平台不支持时退普通移动，仍不覆盖）。
     */
    public MoveOutcome moveInto(Path temp, String storageKey) throws IOException {
        Path target = blobPath(storageKey);
        Files.createDirectories(target.getParent());
        if (Files.exists(target)) {
            return MoveOutcome.TARGET_EXISTS;
        }
        try {
            Files.move(temp, target, StandardCopyOption.ATOMIC_MOVE);
        } catch (FileAlreadyExistsException e) {
            return MoveOutcome.TARGET_EXISTS;
        } catch (AtomicMoveNotSupportedException e) {
            try {
                Files.move(temp, target);
            } catch (FileAlreadyExistsException e2) {
                return MoveOutcome.TARGET_EXISTS;
            }
        }
        return MoveOutcome.MOVED;
    }

    public void deleteTemp(Path temp) {
        if (temp != null) {
            try {
                Files.deleteIfExists(temp);
            } catch (IOException ignored) {
                // 残留临时文件由对账收敛（04-架构与计划 §5；对账属后续任务）
            }
        }
    }

    /** 临时文件的相对临时键（冲突审计 incoming_storage_key 的「临时键」口径，06 §4）。 */
    public String tempKey(Path temp) {
        return tmpDir.relativize(temp).toString().replace('\\', '/');
    }

    public Path tmpDir() {
        return tmpDir;
    }

    public Path dataRoot() {
        return dataRoot;
    }

    /** 计算文件 SHA-256（核对/测试用；不参与上传主路径）。 */
    public String sha256Hex(Path file) throws IOException {
        MessageDigest digest = new Sha256Digester().create();
        try (InputStream in = Files.newInputStream(file)) {
            byte[] buffer = new byte[64 * 1024];
            int read;
            while ((read = in.read(buffer)) > 0) {
                digest.update(buffer, 0, read);
            }
        }
        return HexFormat.of().formatHex(digest.digest());
    }
}
