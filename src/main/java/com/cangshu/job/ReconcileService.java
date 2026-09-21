package com.cangshu.job;

import com.cangshu.catalog.mapper.ContentLocationRow;
import com.cangshu.catalog.mapper.LocationMapper;
import com.cangshu.storage.FileStore;
import java.io.IOException;
import java.io.UncheckedIOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.time.Duration;
import java.time.Instant;
import java.time.OffsetDateTime;
import java.time.ZoneOffset;
import java.util.ArrayList;
import java.util.List;
import java.util.UUID;
import java.util.stream.Stream;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Service;

/**
 * 对账作业（job 模块，任务 28；04-架构与计划 §5 ④、07-运行手册 §6、08-验收规范 §4）。
 *
 * <p>三类核对与修复，**只修不一致，不改回收语义**（04 §5 ④）：
 *
 * <ol>
 *   <li><b>临时文件</b>：{@code <数据根>/tmp/} 下超过设定年龄的残留 → 删除（08 §4「超过设定年龄即删除」）。</li>
 *   <li><b>孤儿字节</b>：数据根有字节而库内没有对应位置行 → 先核对「字节摘要 ＝ 路径里的摘要」，
 *       相符则**隔离**到 {@code <数据根>/orphan/<原相对键>}（只移动、**绝不覆盖**）；不符则同样隔离
 *       但计入「不可信」并告警。</li>
 *   <li><b>缺失字节</b>：库内就绪内容但盘上字节不在或大小与内容身份不符 → 只记录并告警，
 *       **不自动改状态**（自动「转回收」会把仍被引用的资源彻底变不可读，属改回收语义）。</li>
 * </ol>
 *
 * <p>规模取向：对账是每日作业，按 ACC-G1 的百万级元数据设计，因此**分批**——孤儿判定「一批键一次 IN」，
 * 缺失判定「按内容主键分页」，全程内存只驻留一批／一页。
 *
 * <p>为什么孤儿选「隔离」而不是「补行」：08 §4 允许「按策略补行或隔离」；补行会凭空造出无人引用的
 * 内容行，让引用语义与 GC 的判定面变模糊，隔离则不动语义、可逆、可人工复核。
 */
@Service
public class ReconcileService {

    private static final Logger log = LoggerFactory.getLogger(ReconcileService.class);

    /** 临时文件年龄阈值（08 §4「超过设定年龄即删除」的设定值；初始工程参数）。 */
    static final Duration TMP_MAX_AGE = Duration.ofHours(24);
    /** 孤儿判定每批键数（一次 IN 查询的规模）。 */
    static final int KEY_BATCH_SIZE = 1000;
    /** 缺失判定每页内容行数。 */
    static final int PAGE_SIZE = 1000;
    /** 隔离区目录名（数据根下）。 */
    static final String ORPHAN_DIR = "orphan";
    /** 临时区目录名（数据根下）。 */
    static final String TMP_DIR = "tmp";

    private final FileStore files;
    private final LocationMapper locationMapper;

    public ReconcileService(FileStore files, LocationMapper locationMapper) {
        this.files = files;
        this.locationMapper = locationMapper;
    }

    /** 一轮对账结果（结构化摘要）。 */
    public record ReconcileReport(OffsetDateTime startedAt, int tempDeleted, int orphanFound,
            int orphanQuarantined, int orphanUntrusted, int contentsChecked, int bytesMissing,
            int sizeMismatch, int malformedKeys, List<String> notes) {

        public boolean needsAttention() {
            return orphanUntrusted > 0 || bytesMissing > 0 || sizeMismatch > 0 || malformedKeys > 0
                    || !notes.isEmpty();
        }

        public String summary() {
            return "reconcile|tempDeleted=" + tempDeleted + "|orphanFound=" + orphanFound
                    + "|orphanQuarantined=" + orphanQuarantined + "|orphanUntrusted=" + orphanUntrusted
                    + "|contentsChecked=" + contentsChecked + "|bytesMissing=" + bytesMissing
                    + "|sizeMismatch=" + sizeMismatch + "|malformedKeys=" + malformedKeys
                    + "|needsAttention=" + needsAttention();
        }
    }

    public ReconcileReport runOnce() {
        OffsetDateTime startedAt = OffsetDateTime.now(ZoneOffset.UTC);
        List<String> notes = new ArrayList<>();

        int tempDeleted = cleanTemporaryFiles();

        OrphanScan orphans = scanOrphans(notes);

        MissingScan missing = scanMissing(notes);

        ReconcileReport report = new ReconcileReport(startedAt, tempDeleted, orphans.found(),
                orphans.quarantined(), orphans.untrusted(), missing.checked(), missing.missing(),
                missing.sizeMismatch(), missing.malformedKeys(), notes);
        log.info("CANGSHU|job|reconcile|{}", report.summary());
        notes.forEach(note -> log.warn("CANGSHU|job|reconcile|alert|{}", note));
        return report;
    }

    // ────────────────────────── ① 临时文件 ──────────────────────────

    private int cleanTemporaryFiles() {
        Path tmp = files.tmpDir();
        if (!Files.isDirectory(tmp)) {
            return 0;
        }
        Instant cutoff = Instant.now().minus(TMP_MAX_AGE);
        int deleted = 0;
        try (Stream<Path> walk = Files.walk(tmp)) {
            for (Path path : walk.filter(Files::isRegularFile).toList()) {
                try {
                    if (Files.getLastModifiedTime(path).toInstant().isBefore(cutoff)) {
                        Files.deleteIfExists(path);
                        deleted++;
                    }
                } catch (IOException e) {
                    log.warn("CANGSHU|job|reconcile|临时文件删除失败：{}（{}）", path, e.getMessage());
                }
            }
        } catch (IOException e) {
            throw new UncheckedIOException(e);
        }
        return deleted;
    }

    // ────────────────────────── ② 孤儿字节 ──────────────────────────

    private record OrphanScan(int found, int quarantined, int untrusted) {
    }

    private OrphanScan scanOrphans(List<String> notes) {
        Path root = files.dataRoot();
        if (!Files.isDirectory(root)) {
            return new OrphanScan(0, 0, 0);
        }
        int found = 0;
        int quarantined = 0;
        int untrusted = 0;
        List<String> batch = new ArrayList<>(KEY_BATCH_SIZE);
        try (Stream<Path> walk = Files.walk(root)) {
            for (Path file : walk.filter(Files::isRegularFile).toList()) {
                String key = relativeKey(root, file);
                if (key.startsWith(TMP_DIR + "/") || key.startsWith(ORPHAN_DIR + "/")) {
                    continue;   // 临时区由 ① 管；隔离区不再重复扫
                }
                batch.add(key);
                if (batch.size() >= KEY_BATCH_SIZE) {
                    OrphanBatchResult result = flushOrphanBatch(batch, notes);
                    found += result.found();
                    quarantined += result.quarantined();
                    untrusted += result.untrusted();
                    batch = new ArrayList<>(KEY_BATCH_SIZE);
                }
            }
        } catch (IOException e) {
            throw new UncheckedIOException(e);
        }
        OrphanBatchResult tail = flushOrphanBatch(batch, notes);
        found += tail.found();
        quarantined += tail.quarantined();
        untrusted += tail.untrusted();
        return new OrphanScan(found, quarantined, untrusted);
    }

    private record OrphanBatchResult(int found, int quarantined, int untrusted) {
    }

    /** 一批键一次 IN 查询：查不到的即孤儿，逐个核对摘要后隔离（绝不覆盖）。 */
    private OrphanBatchResult flushOrphanBatch(List<String> batch, List<String> notes) {
        if (batch.isEmpty()) {
            return new OrphanBatchResult(0, 0, 0);
        }
        List<String> registered = locationMapper.findExistingKeys(batch);
        List<String> orphans = batch.stream().filter(key -> !registered.contains(key)).toList();
        int quarantined = 0;
        int untrusted = 0;
        for (String key : orphans) {
            Path source = files.dataRoot().resolve(key);
            boolean trusted = digestMatchesPath(source, key);
            if (quarantine(key)) {
                quarantined++;
            }
            if (!trusted) {
                untrusted++;
                notes.add("孤儿字节与其路径摘要不符（不可信，已隔离待人工复核）：" + key);
            }
            log.warn("CANGSHU|job|reconcile|orphan|storageKey={}|trusted={}", key, trusted);
        }
        return new OrphanBatchResult(orphans.size(), quarantined, untrusted);
    }

    /** 路径里的摘要与文件实际摘要是否相符（08 §4：先核对相符性，再决定处置）。 */
    private boolean digestMatchesPath(Path file, String key) {
        String name = key.substring(key.lastIndexOf('/') + 1);
        if (!name.matches("[0-9a-f]{64}")) {
            return false;
        }
        try {
            return files.sha256Hex(file).equalsIgnoreCase(name);
        } catch (IOException e) {
            return false;
        }
    }

    /** 隔离：移动到 {@code <数据根>/orphan/<原相对键>}；目标已存在则**放弃移动**，绝不覆盖。 */
    private boolean quarantine(String key) {
        Path root = files.dataRoot();
        Path source = root.resolve(key);
        Path target = root.resolve(ORPHAN_DIR).resolve(key);
        try {
            if (Files.exists(target)) {
                log.warn("CANGSHU|job|reconcile|隔离目标已存在，放弃移动（绝不覆盖）：{}", target);
                return false;
            }
            Files.createDirectories(target.getParent());
            Files.move(source, target, StandardCopyOption.ATOMIC_MOVE);
            return true;
        } catch (IOException e) {
            log.warn("CANGSHU|job|reconcile|隔离失败：{}（{}）", key, e.getMessage());
            return false;
        }
    }

    // ────────────────────────── ③ 缺失字节 ──────────────────────────

    private record MissingScan(int checked, int missing, int sizeMismatch, int malformedKeys) {
    }

    /**
     * 缺失判定：按内容主键分页，只看**就绪**内容（已回收／回收中的内容本就不该有字节）。
     * 比对的是「字节在不在 ＋ 盘上大小 ＝ 内容身份大小」——全量摘要比对很重，留在 GC 段二
     * （删字节前）与下载路径上做，这里不做第二遍。
     *
     * <p>库里的位置键可能来自历史版本或被人工改坏（形状不合法）：那属于**要报告的数据异常**，
     * 记入 {@code malformedKeys} 并告警，绝不因为一条坏键就让整个作业抛异常中断。
     */
    private MissingScan scanMissing(List<String> notes) {
        int checked = 0;
        int missing = 0;
        int sizeMismatch = 0;
        int malformedKeys = 0;
        UUID afterId = new UUID(0L, 0L);
        while (true) {
            List<ContentLocationRow> page = locationMapper.pageContentWithLocation(afterId, PAGE_SIZE);
            if (page.isEmpty()) {
                return new MissingScan(checked, missing, sizeMismatch, malformedKeys);
            }
            for (ContentLocationRow row : page) {
                afterId = row.getContentId();
                if (!"READY".equals(row.getStatus())) {
                    continue;
                }
                checked++;
                if (row.getStorageKey() == null) {
                    missing++;
                    notes.add("就绪内容缺位置行（拒绝下载／拒绝还原）：contentId=" + row.getContentId());
                    continue;
                }
                if (!files.isWellFormedKey(row.getStorageKey())) {
                    malformedKeys++;
                    notes.add("位置键形状非法（拒绝下载／拒绝还原，需人工修数据）：contentId="
                            + row.getContentId() + "|storageKey=" + row.getStorageKey());
                    continue;
                }
                Path blob = files.blobPath(row.getStorageKey());
                if (!Files.isRegularFile(blob)) {
                    missing++;
                    notes.add("就绪内容字节缺失（最高危：拒绝下载／拒绝还原）：contentId=" + row.getContentId()
                            + "|storageKey=" + row.getStorageKey());
                    continue;
                }
                try {
                    long onDisk = Files.size(blob);
                    if (row.getSizeBytes() != null && onDisk != row.getSizeBytes()) {
                        sizeMismatch++;
                        notes.add("盘上字节大小与内容身份不符：contentId=" + row.getContentId()
                                + "|盘上=" + onDisk + "|身份=" + row.getSizeBytes());
                    }
                } catch (IOException e) {
                    notes.add("读取字节大小失败：contentId=" + row.getContentId() + "|" + e.getMessage());
                }
            }
        }
    }

    private static String relativeKey(Path root, Path file) {
        return root.relativize(file).toString().replace('\\', '/');
    }
}
