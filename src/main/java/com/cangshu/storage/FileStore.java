package com.cangshu.storage;

import com.cangshu.common.StagedUpload;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.nio.file.AtomicMoveNotSupportedException;
import java.nio.file.FileAlreadyExistsException;
import java.nio.file.Files;
import java.nio.file.InvalidPathException;
import java.nio.file.LinkOption;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.security.MessageDigest;
import java.util.HexFormat;
import java.util.Locale;
import java.util.regex.Pattern;

/**
 * 内容寻址字节层（storage 模块；04-架构与计划 §1：不认识资源业务概念、不写数据库）。
 *
 * <p>物理存储键＝{@code sha256/ab/cd/<digest>}（ab＝摘要第 1–2 位、cd＝第 3–4 位；相对键，
 * 不含数据根前缀，06-数据契约 §5）。临时区 {@code <data-root>/tmp/} 与正式区同在数据根下
 * （同一文件系统，移动才成立）。业务层只使用相对存储键，路径解析只在 storage 内部。
 * 数据根由装配层注入（{@code config.StorageConfiguration}，P0-3④ D），本类不读配置绑定面。
 */
public class FileStore {

    /** 相对存储键的安全形状：小写字母数字首段 ＋ 两段两位十六进制 ＋ 64 位摘要。 */
    private static final Pattern STORAGE_KEY_PATTERN =
            Pattern.compile("[a-z0-9]+/[0-9a-f]{2}/[0-9a-f]{2}/[0-9a-f]{64}");

    /** 隔离区目录名（数据根下；对账的孤儿字节隔离目标，07-运行手册 §6／08-验收规范 §4）。 */
    public static final String ORPHAN_DIR_NAME = "orphan";

    private final Path dataRoot;
    private final Path tmpDir;
    private final String neverMoveName;

    /**
     * 数据根由装配层解析后注入（P0-3④ D）：本类只接受**已解析的数据根路径**，不读
     * {@code cangshu.*} 绑定面——配置绑定、相对路径规范化与启动记录都留在 config 装配层
     * （07-运行手册 §1「启动解析并记录规范绝对路径」）。这里仍做一次幂等的
     * {@code toAbsolutePath().normalize()}，使直接构造（测试、嵌入）也得到同一条规范路径。
     */
    public FileStore(Path dataRoot, String neverMoveName) {
        this.dataRoot = dataRoot.toAbsolutePath().normalize();
        this.tmpDir = this.dataRoot.resolve("tmp");
        if (neverMoveName == null || neverMoveName.isBlank()) {
            throw new IllegalArgumentException("门协议锁文件名未注入：装配层必须显式传入");
        }
        this.neverMoveName = neverMoveName;
    }

    /**
     * 上传第一步：流式落临时文件并同时计算摘要，不把完整文件读入内存（REQ-M1-02）。
     *
     * <p>超过 {@code maxBytes} 立即中止并清理临时文件；目录懒创建（启动门属任务 29，
     * 本任务无启动门，但保持「首次写盘才建目录」的最小副作用原则）。
     */
    public StagedUpload stage(InputStream in, long maxBytes, Digestor digestor) throws IOException {
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
        return new StagedUpload(temp, digestor.canonicalAlgorithm(), HexFormat.of().formatHex(digest.digest()), total);
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

    /**
     * 存储键形状是否合法（{@code <命名空间>/<两位>/<两位>/<64位摘要>}）。
     * 供对账等**读库取键**的路径先判形状：库里的键可能来自历史版本或被人工改坏，
     * 那种情况是要报告的数据异常，不是该抛异常中断作业的理由。
     */
    public boolean isWellFormedKey(String storageKey) {
        return storageKey != null && STORAGE_KEY_PATTERN.matcher(storageKey).matches();
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

    /**
     * 幂等删除内容地址上的字节（GC 段二，04 §5 ③）：**文件已缺即视为成功**，不抛异常——
     * 段二被杀在删字节前／后，下次重扫的两种情形都必须幂等通过。
     *
     * <p>只删目标键本身；不递归、不清理空目录（空目录不占空间，也不参与任何判定）。
     */
    public void deleteBlob(String storageKey) throws IOException {
        Files.deleteIfExists(blobPath(storageKey));
    }

    /** 隔离移动的结果（对账孤儿字节处置；本类只做字节移动，不取锁、不写数据库）。 */
    public enum OrphanOutcome {
        /** 已把字节移动到隔离区（绝不覆盖）。 */
        MOVED,
        /** 隔离目标已存在：放弃移动、源与目标都不动（绝不覆盖），留人工复核。 */
        TARGET_EXISTS,
        /** 源字节已不在原位置（已被别处收敛或删除）：无移动。 */
        SOURCE_MISSING
    }

    /**
     * 隔离移动（对账处置孤儿字节的**唯一**字节层入口）：把内容地址上的字节原子移动到
     * {@code <数据根>/orphan/<原相对键>}，**目标已存在即放弃移动且绝不覆盖**（08 §4）。
     *
     * <p>为什么下沉到 storage：绝对路径的解析与「移动」这一动作只属于本类（04-架构与计划 §1 的
     * 模块边界），job 侧不得自行拼路径后 {@code Files.move}。
     *
     * <p><b>调用方必须在持有该内容身份分段锁时调用</b>（04 §6 :107「六类共锁」）：本方法不取锁、
     * 不认识内容身份、不写数据库，锁的所有权由调用方（catalog／job）明确持有。
     *
     * <p>键是<b>数据根内的相对键</b>：形状不合法的键（历史残留、非内容地址文件）也允许移动——它们
     * 只能是「隔离」而不能是「删除」，这是对账「绝不盲删」的口径。
     *
     * <p><b>单写者门协议文件不是字节对象</b>：{@code .cangshu-writer.lock} 是被启动门加锁的互斥标记，
     * 把它挪走等于在原路径留下一个全新的、无人加锁的同名文件，门的互斥随之失效。因此这里显式拒绝
     * （形状检查之外再兜一层），任何调用方都不得以任何理由移动它。
     *
     * @throws IllegalArgumentException 键为空、是绝对路径、逃出数据根，或键是单写者门协议文件
     */
    public OrphanOutcome moveToOrphan(String relativeKey) throws IOException {
        Path source = isolationSource(relativeKey);
        if (!Files.exists(source)) {
            return OrphanOutcome.SOURCE_MISSING;
        }
        if (!Files.isRegularFile(source, LinkOption.NOFOLLOW_LINKS)) {
            throw new IllegalArgumentException("隔离源必须是普通文件：" + relativeKey);
        }
        requireInsideDataRoot(source, relativeKey);
        Path target = dataRoot.resolve(ORPHAN_DIR_NAME).resolve(dataRoot.relativize(source));
        if (Files.exists(target)) {
            return OrphanOutcome.TARGET_EXISTS;
        }
        Files.createDirectories(target.getParent());
        try {
            Files.move(source, target, StandardCopyOption.ATOMIC_MOVE);
        } catch (FileAlreadyExistsException e) {
            return OrphanOutcome.TARGET_EXISTS;
        } catch (AtomicMoveNotSupportedException e) {
            try {
                Files.move(source, target);
            } catch (FileAlreadyExistsException inner) {
                return OrphanOutcome.TARGET_EXISTS;
            }
        }
        return OrphanOutcome.MOVED;
    }

    /** 隔离源路径：只接受数据根内的相对键（拒绝空白、绝对路径、逃出数据根与门协议文件）。 */
    private Path isolationSource(String relativeKey) {
        if (relativeKey == null || relativeKey.isBlank()) {
            throw new IllegalArgumentException("隔离键为空");
        }
        Path source;
        try {
            Path key = Path.of(relativeKey);
            if (key.isAbsolute()) {
                throw new IllegalArgumentException("隔离键必须是相对路径：" + relativeKey);
            }
            source = dataRoot.resolve(key).normalize();
        } catch (InvalidPathException e) {
            throw new IllegalArgumentException("隔离键不是合法路径：" + relativeKey, e);
        }
        if (source.equals(dataRoot) || !source.startsWith(dataRoot)) {
            throw new IllegalArgumentException("隔离键必须落在数据根内的相对路径：" + relativeKey);
        }
        if (isProtocolLockName(source)) {
            throw new IllegalArgumentException("拒绝隔离单写者门协议文件：" + relativeKey);
        }
        return source;
    }

    private boolean isProtocolLockName(Path source) {
        Path name = source.getFileName();
        return name != null && canonicalLockName(name.toString()).equals(canonicalLockName(neverMoveName));
    }

    private static String canonicalLockName(String name) {
        int end = name.length();
        while (end > 0 && (name.charAt(end - 1) == '.' || name.charAt(end - 1) == ' ')) {
            end--;
        }
        return name.substring(0, end).toLowerCase(Locale.ROOT);
    }

    private void requireInsideDataRoot(Path source, String relativeKey) throws IOException {
        Path realRoot = dataRoot.toRealPath();
        Path realSource = source.toRealPath();
        if (!realSource.startsWith(realRoot)) {
            throw new IllegalArgumentException("隔离源的联接指向数据根之外：" + relativeKey);
        }
    }

    /**
     * 隔离目标路径（{@code <数据根>/orphan/<原相对键>}）；仅供核对与测试使用，主路径不调用。
     */
    public Path orphanPath(String relativeKey) {
        return dataRoot.resolve(ORPHAN_DIR_NAME).resolve(dataRoot.relativize(isolationSource(relativeKey)));
    }

    /**
     * 路径里的摘要与内容地址上的字节实际摘要是否相符（08 §4：先核对相符性，再决定处置）。
     * 键形状不符、字节缺失或读取失败都返回 {@code false}——调用方据此记「不可信」，绝不改字节。
     */
    public boolean digestMatchesKey(String storageKey) {
        if (storageKey == null || !STORAGE_KEY_PATTERN.matcher(storageKey).matches()) {
            return false;
        }
        String expected = storageKey.substring(storageKey.lastIndexOf('/') + 1);
        try {
            return sha256Hex(dataRoot.resolve(storageKey)).equalsIgnoreCase(expected);
        } catch (IOException e) {
            return false;
        }
    }

    /** 临时文件的相对临时键（冲突审计 incoming_storage_key 的「临时键」口径，06 §4）。 */
    public String tempKey(Path temp) {
        return tmpDir.relativize(temp).toString().replace('\\', '/');
    }

    /** 临时文件所在目录（供核对与测试使用；生产主路径不调用）。 */
    public Path tmpDir() {
        return tmpDir;
    }

    /** 数据根（供对账扫描内容地址与临时区使用；业务层不解析绝对路径）。 */
    public Path dataRoot() {
        return dataRoot;
    }

    /** 计算文件 SHA-256（供核对与测试使用；不参与上传主路径）。 */
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
