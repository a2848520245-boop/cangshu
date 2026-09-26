package com.cangshu.job;

import com.baomidou.mybatisplus.core.toolkit.Wrappers;
import com.cangshu.catalog.entity.ContentEntity;
import com.cangshu.catalog.mapper.ContentLocationRow;
import com.cangshu.catalog.mapper.ContentMapper;
import com.cangshu.catalog.mapper.LocationMapper;
import com.cangshu.config.WriterGate;
import com.cangshu.storage.Algorithms;
import com.cangshu.storage.FileStore;
import com.cangshu.storage.LockTimeoutException;
import com.cangshu.storage.SegmentLockManager;
import java.io.IOException;
import java.io.UncheckedIOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.Duration;
import java.time.Instant;
import java.time.OffsetDateTime;
import java.time.ZoneOffset;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.Set;
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
 * <p><b>与上传／复用／还原／删除／GC 共用同一把分段锁</b>（04-架构与计划 §6 第 107 行「六类共锁」；
 * 锁键＝规范算法 {@code SHA-256} ＋ 小写摘要，**不含大小**）：对账的每一次「判定后处置」都在
 * {@link SegmentLockManager} 的内容身份锁内完成。锁外只允许产出**候选**——「一批键一次 IN 查不到」
 * 与「一页内容行看起来就绪」都只是候选；判定、字节检查、隔离移动一律以**锁内重读**的结果为准。
 * 这不是优化项：上传在 {@code CatalogService.attemptLocked} 里「已 {@code moveInto}、位置行尚未提交」
 * 的窗口内正持着同一把锁，凭锁外快照移动字节会把一次进行中的上传的正式字节误隔离。
 *
 * <p><b>不是字节对象的东西不参与孤儿判定</b>：数据根下的单写者门协议文件 {@code .cangshu-writer.lock}
 * （任务 29，{@link WriterGate#LOCK_FILE_NAME}）是被启动门持有并加锁的标记。隔离它＝把它挪走，
 * 于是原路径上会出现一个全新的、无人加锁的同名文件，第二个写者就能拿到文件锁——门的互斥被悄悄取消。
 * 因此孤儿扫描阶段直接跳过它（与 {@code tmp/}、{@code orphan/} 同属「不按字节对象处理」的范围）。
 *
 * <p>为什么孤儿选「隔离」而不是「补行」：08 §4 允许「按策略补行或隔离」；补行会凭空造出无人引用的
 * 内容行，让引用语义与 GC 的判定面变模糊，隔离则不动语义、可逆、可人工复核。
 */
@Service
public class ReconcileService {

    private static final Logger log = LoggerFactory.getLogger(ReconcileService.class);

    /** 内容就绪态（与 {@code CatalogService} 同一词表；对账只看就绪内容该不该有字节）。 */
    private static final String CONTENT_STATUS_READY = "READY";

    /** 临时文件年龄阈值（08 §4「超过设定年龄即删除」的设定值；初始工程参数）。 */
    static final Duration TMP_MAX_AGE = Duration.ofHours(24);
    /** 孤儿判定每批键数（一次 IN 查询的规模）。 */
    static final int KEY_BATCH_SIZE = 1000;
    /** 缺失判定每页内容行数。 */
    static final int PAGE_SIZE = 1000;
    /** 隔离区目录名（数据根下；取值来自字节层，避免两处各写一份）。 */
    static final String ORPHAN_DIR = FileStore.ORPHAN_DIR_NAME;
    /** 临时区目录名（数据根下）。 */
    static final String TMP_DIR = "tmp";

    private final FileStore files;
    private final ContentMapper contentMapper;
    private final LocationMapper locationMapper;
    private final SegmentLockManager locks;

    public ReconcileService(FileStore files, ContentMapper contentMapper, LocationMapper locationMapper,
            SegmentLockManager locks) {
        this.files = files;
        this.contentMapper = contentMapper;
        this.locationMapper = locationMapper;
        this.locks = locks;
    }

    /**
     * 一轮对账结果（结构化摘要）。
     *
     * <p>计数口径：{@code orphanFound} ＝**锁内重读后**仍未登记、判定为孤儿的键数（锁外候选不算数）；
     * {@code orphanConverged} ＝锁外看着像孤儿、锁内重读发现已被上传／复用登记（已收敛，字节一根不动）；
     * {@code orphanQuarantined} ⊆ {@code orphanFound} ＝真正移动进隔离区的键数。
     */
    public record ReconcileReport(OffsetDateTime startedAt, int tempDeleted, int orphanFound,
            int orphanQuarantined, int orphanUntrusted, int orphanConverged, int contentsChecked,
            int bytesMissing, int sizeMismatch, int malformedKeys, List<String> notes) {

        public boolean needsAttention() {
            return orphanUntrusted > 0 || bytesMissing > 0 || sizeMismatch > 0 || malformedKeys > 0
                    || !notes.isEmpty();
        }

        public String summary() {
            return "reconcile|tempDeleted=" + tempDeleted + "|orphanFound=" + orphanFound
                    + "|orphanQuarantined=" + orphanQuarantined + "|orphanUntrusted=" + orphanUntrusted
                    + "|orphanConverged=" + orphanConverged
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
                orphans.quarantined(), orphans.untrusted(), orphans.converged(), missing.checked(),
                missing.missing(), missing.sizeMismatch(), missing.malformedKeys(), notes);
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

    private record OrphanScan(int found, int quarantined, int untrusted, int converged) {
    }

    /**
     * 扫描候选：走一遍数据根，产出「可能是孤儿」的候选键，分批交给 {@link #flushOrphanBatch}。
     * 本方法**不作判定**——判定与处置都在分段锁内重读之后进行（04-架构与计划 §6 第 107 行）。
     */
    private OrphanScan scanOrphans(List<String> notes) {
        Path root = files.dataRoot();
        if (!Files.isDirectory(root)) {
            return new OrphanScan(0, 0, 0, 0);
        }
        int found = 0;
        int quarantined = 0;
        int untrusted = 0;
        int converged = 0;
        List<String> batch = new ArrayList<>(KEY_BATCH_SIZE);
        try (Stream<Path> walk = Files.walk(root)) {
            for (Path file : walk.filter(Files::isRegularFile).toList()) {
                String key = relativeKey(root, file);
                if (key.startsWith(TMP_DIR + "/") || key.startsWith(ORPHAN_DIR + "/")) {
                    continue;   // 临时区由 ① 管；隔离区不再重复扫
                }
                if (key.equals(WriterGate.LOCK_FILE_NAME)) {
                    continue;   // 单写者门的协议锁文件：移动它等于把互斥对象换成一个新文件，门就失效了
                }
                batch.add(key);
                if (batch.size() >= KEY_BATCH_SIZE) {
                    OrphanBatchResult result = flushOrphanBatch(batch, notes);
                    found += result.found();
                    quarantined += result.quarantined();
                    untrusted += result.untrusted();
                    converged += result.converged();
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
        converged += tail.converged();
        return new OrphanScan(found, quarantined, untrusted, converged);
    }

    private record OrphanBatchResult(int found, int quarantined, int untrusted, int converged) {
    }

    /** 单个孤儿候选的处置结果。 */
    private enum OrphanVerdict {
        /** 确认孤儿（锁内重读后仍未登记）并已移动进隔离区。 */
        QUARANTINED,
        /** 确认孤儿但没能移动（目标已存在／IO 失败）：源字节仍在原处，下次对账重试。 */
        CONFIRMED_NOT_MOVED,
        /** 锁外像孤儿、锁内重读发现已被上传／复用登记：已收敛，不移动、不删除。 */
        CONVERGED,
        /** 位置行虽已删除，内容身份仍归属这些字节；留给 GC 续接或人工复核。 */
        CONTENT_OWNED,
        /** 取分段锁超时：本轮未做任何判定与字节处置。 */
        UNDECIDED
    }

    /** 单个候选的处置结果与「不可信」标记（两者分别落桶计数）。 */
    private record OrphanSettlement(OrphanVerdict verdict, boolean untrusted) {
    }

    /**
     * 一批键一次 IN 查询：查不到的**只是候选**，逐个走「取分段锁 → 锁内重读 → 锁内核对摘要 → 锁内隔离」
     * （04-架构与计划 §6 第 107 行「六类共锁」）。锁外那一批 IN 只用来排除确定已登记的键，不作判定依据。
     */
    private OrphanBatchResult flushOrphanBatch(List<String> batch, List<String> notes) {
        if (batch.isEmpty()) {
            return new OrphanBatchResult(0, 0, 0, 0);
        }
        Set<String> registered = new HashSet<>(locationMapper.findExistingKeys(batch));
        int found = 0;
        int quarantined = 0;
        int untrusted = 0;
        int converged = 0;
        for (String key : batch) {
            if (registered.contains(key)) {
                continue;
            }
            OrphanSettlement settlement = settleOrphanCandidate(key, notes);
            if (settlement.untrusted()) {
                untrusted++;
            }
            switch (settlement.verdict()) {
                case QUARANTINED -> {
                    found++;
                    quarantined++;
                }
                case CONFIRMED_NOT_MOVED -> found++;
                case CONVERGED -> converged++;
                case CONTENT_OWNED -> {
                    // 内容仍拥有这些字节，不能计作孤儿或位置行收敛。
                }
                case UNDECIDED -> {
                    // 取锁超时：已记 notes（作业随之要求人工介入），不做任何字节处置
                }
            }
        }
        return new OrphanBatchResult(found, quarantined, untrusted, converged);
    }

    /**
     * 单个候选的完整处置：**取分段锁 → 锁内重读 → 锁内核对摘要 → 锁内隔离**（04 §6 :107）。
     *
     * <p>为什么必须共锁：上传在 {@code CatalogService.attemptLocked} 里「已 {@code moveInto}、位置行
     * 尚未提交」的窗口内正持着同一把锁。凭锁外快照（那一刻位置行还查不到）移动字节，就是把一次正在
     * 进行中的上传的正式字节误隔离。只有**锁内重读后仍未登记**，才谈得上「孤儿」。
     *
     * <p>形状不合法的键（历史残留、被人工放进数据根的文件）没有可共锁的内容身份——上传／复用／还原
     * 建立的键恒为 {@code <命名空间>/xx/yy/<64 位摘要>}，这类键不可能是并发写者正在建立中的字节。
     * 它们仍按「只隔离、绝不删」处置，并记 {@code untrusted} 待人工复核。
     */
    private OrphanSettlement settleOrphanCandidate(String key, List<String> notes) {
        String algorithm = canonicalAlgorithmOf(key);
        if (algorithm == null) {
            boolean trusted = files.digestMatchesKey(key);
            return new OrphanSettlement(quarantine(key, trusted, notes), !trusted);
        }
        try (SegmentLockManager.Handle handle = locks.acquire(algorithm, digestOf(key))) {
            if (!locationMapper.findExistingKeys(List.of(key)).isEmpty()) {
                log.info("CANGSHU|job|reconcile|orphan|converged|storageKey={}", key);
                return new OrphanSettlement(OrphanVerdict.CONVERGED, false);
            }
            if (contentStillOwnsBytes(key, algorithm, notes)) {
                return new OrphanSettlement(OrphanVerdict.CONTENT_OWNED, false);
            }
            boolean trusted = files.digestMatchesKey(key);
            return new OrphanSettlement(quarantine(key, trusted, notes), !trusted);
        } catch (LockTimeoutException e) {
            notes.add("孤儿候选取分段锁超时（" + SegmentLockManager.WAIT_TIMEOUT_SECONDS
                    + " 秒），本轮未做任何字节处置（可重跑）：storageKey=" + key);
            return new OrphanSettlement(OrphanVerdict.UNDECIDED, false);
        }
    }

    /** GC 段一先删位置行，再由段二删字节；无位置行不能单独证明字节是孤儿。 */
    private boolean contentStillOwnsBytes(String key, String algorithm, List<String> notes) {
        List<ContentEntity> contents = contentMapper.selectList(Wrappers.<ContentEntity>lambdaQuery()
                .eq(ContentEntity::getHashAlgorithm, algorithm)
                .eq(ContentEntity::getDigest, digestOf(key)));
        List<ContentEntity> owners = contents.stream()
                .filter(content -> !"RECLAIMED".equals(content.getStatus()))
                .toList();
        if (owners.isEmpty()) {
            return false;
        }
        String message;
        if (owners.size() != 1 || contents.size() != 1) {
            message = "同算法摘要存在多条内容身份，位置行缺失，原位保留待人工复核："
                    + contents.stream().map(content -> content.getId() + ":" + content.getStatus()).toList();
        } else {
            ContentEntity owner = owners.get(0);
            Long expectedSize = owner.getSizeBytes();
            try {
                long actualSize = Files.size(files.blobPath(key));
                if (expectedSize == null || expectedSize != actualSize) {
                    message = "内容身份大小与盘上字节不符，位置行缺失，原位保留待人工复核：contentId="
                            + owner.getId() + "|status=" + owner.getStatus()
                            + "|身份=" + expectedSize + "|盘上=" + actualSize;
                } else if ("RECLAIMING".equals(owner.getStatus())) {
                    message = "启动对账发现残留 RECLAIMING，位置行已删且字节仍在，原位保留待 GC 续接：contentId="
                            + owner.getId();
                } else {
                    message = "内容身份仍未回收但位置行缺失，原位保留待人工复核：contentId="
                            + owner.getId() + "|status=" + owner.getStatus();
                }
            } catch (IOException e) {
                message = "读取内容字节大小失败，原位保留待人工复核：contentId=" + owner.getId()
                        + "|status=" + owner.getStatus() + "|" + e.getMessage();
            }
        }
        notes.add(message + "|storageKey=" + key);
        return true;
    }

    /**
     * 隔离（移动到 {@code <数据根>/orphan/<原相对键>}，**目标已存在即放弃移动、绝不覆盖**）：字节动作
     * 下沉在 {@link FileStore#moveToOrphan}，本方法只负责记日志、记「不可信」与返回计数口径。
     */
    private OrphanVerdict quarantine(String key, boolean trusted, List<String> notes) {
        FileStore.OrphanOutcome outcome;
        try {
            outcome = files.moveToOrphan(key);
        } catch (IOException | IllegalArgumentException e) {
            log.warn("CANGSHU|job|reconcile|隔离失败，源字节留在原处（下次对账重试）：{}（{}）", key, e.getMessage());
            return OrphanVerdict.CONFIRMED_NOT_MOVED;
        }
        if (outcome == FileStore.OrphanOutcome.TARGET_EXISTS) {
            log.warn("CANGSHU|job|reconcile|隔离目标已存在，放弃移动（绝不覆盖）：orphan/{}", key);
        } else if (outcome == FileStore.OrphanOutcome.SOURCE_MISSING) {
            log.warn("CANGSHU|job|reconcile|源字节已不在内容地址（已被别处收敛），不移动：{}", key);
        }
        if (!trusted) {
            notes.add("孤儿字节与其路径摘要不符（不可信，已隔离待人工复核）：" + key);
        }
        log.warn("CANGSHU|job|reconcile|orphan|storageKey={}|trusted={}", key, trusted);
        return outcome == FileStore.OrphanOutcome.MOVED
                ? OrphanVerdict.QUARANTINED : OrphanVerdict.CONFIRMED_NOT_MOVED;
    }

    /**
     * 孤儿键 → 分段锁的规范算法：只有**形状合法**的内容地址键才对应一个真实内容身份、才谈得上与上传
     * 共锁；其余键（历史残留、人工放进数据根的文件、非本系统命名空间）返回 {@code null}。
     */
    private String canonicalAlgorithmOf(String key) {
        if (!files.isWellFormedKey(key)) {
            return null;
        }
        return Algorithms.canonicalOfNamespace(key.substring(0, key.indexOf('/')));
    }

    /** 内容地址键里的摘要段（决定落在哪一段锁上）。 */
    private static String digestOf(String key) {
        return key.substring(key.lastIndexOf('/') + 1);
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
     *
     * <p>分页结果**只是候选**：判定一律在「取该内容身份的分段锁 → 锁内重读内容与位置行」之后进行
     * （04 §6 :107「六类共锁」）。理由与孤儿侧相同——上传／复用／还原／GC 正在同一把锁内改这些行，
     * 锁外那一页可能已经是过去式：已被回收的内容不该再报缺字节，正在复活的字节不该被当成缺失。
     */
    private MissingScan scanMissing(List<String> notes) {
        int checked = 0;
        int missing = 0;
        int sizeMismatch = 0;
        int malformedKeys = 0;
        Set<UUID> reportedReclaiming = new HashSet<>();
        UUID afterId = new UUID(0L, 0L);
        while (true) {
            List<ContentLocationRow> page = locationMapper.pageContentWithLocation(afterId, PAGE_SIZE);
            if (page.isEmpty()) {
                return new MissingScan(checked, missing, sizeMismatch, malformedKeys);
            }
            for (ContentLocationRow candidate : page) {
                afterId = candidate.getContentId();
                if ("RECLAIMING".equals(candidate.getStatus())) {
                    reportReclaiming(candidate, notes, reportedReclaiming);
                    continue;
                }
                if (!CONTENT_STATUS_READY.equals(candidate.getStatus())) {
                    continue;
                }
                String algorithm = lockIdentityOrNull(candidate, notes);
                if (algorithm == null) {
                    malformedKeys++;
                    continue;
                }
                try (SegmentLockManager.Handle handle = locks.acquire(algorithm, candidate.getDigest())) {
                    List<ContentLocationRow> current =
                            locationMapper.findContentLocation(candidate.getContentId());
                    if (current.isEmpty()) {
                        continue;   // 内容行已消失：没有可告警的对象
                    }
                    if (current.size() > 1) {
                        malformedKeys++;
                        notes.add("内容的位置记录数异常（拒绝下载／拒绝还原，需人工修数据）：contentId="
                                + candidate.getContentId() + "|rows=" + current.size());
                        continue;
                    }
                    ContentLocationRow row = current.get(0);
                    if (!CONTENT_STATUS_READY.equals(row.getStatus())) {
                        continue;   // 锁内已是回收态：按新状态跳过，字节归属 GC 的回收语义
                    }
                    if (!candidate.getDigest().equals(row.getDigest())) {
                        malformedKeys++;
                        notes.add("内容身份在判定期间发生变化（拒绝下载／拒绝还原，需人工复核）：contentId="
                                + candidate.getContentId() + "|候选摘要=" + candidate.getDigest()
                                + "|当前摘要=" + row.getDigest());
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
                } catch (LockTimeoutException e) {
                    notes.add("缺失判定取分段锁超时（" + SegmentLockManager.WAIT_TIMEOUT_SECONDS
                            + " 秒），本轮未判定（可重跑）：contentId=" + candidate.getContentId());
                }
            }
        }
    }

    /** 字节已缺的 GC 段三残留也须在启动对账报告；分页候选必须锁内重读确认。 */
    private void reportReclaiming(ContentLocationRow candidate, List<String> notes,
            Set<UUID> reportedReclaiming) {
        String algorithm = lockIdentityOrNull(candidate, notes);
        if (algorithm == null) {
            return;
        }
        try (SegmentLockManager.Handle handle = locks.acquire(algorithm, candidate.getDigest())) {
            List<ContentLocationRow> current = locationMapper.findContentLocation(candidate.getContentId());
            if (current.stream().anyMatch(row -> "RECLAIMING".equals(row.getStatus()))
                    && reportedReclaiming.add(candidate.getContentId())) {
                notes.add("启动对账发现残留 RECLAIMING，待 GC 续接：contentId=" + candidate.getContentId()
                        + (current.size() > 1 ? "|位置记录数异常=" + current.size() + "，需人工复核" : ""));
            }
        } catch (LockTimeoutException e) {
            notes.add("回收中状态复核取分段锁超时，本轮未判定：contentId=" + candidate.getContentId());
        }
    }

    /**
     * 候选行 → 分段锁的规范算法（{@link Algorithms#canonical}：库内别名必须先归一，不得绕开锁）；
     * 算法或摘要不成内容身份时返回 {@code null} 并登记数据异常。
     */
    private String lockIdentityOrNull(ContentLocationRow candidate, List<String> notes) {
        String algorithm;
        try {
            algorithm = Algorithms.canonical(candidate.getHashAlgorithm());
        } catch (IllegalArgumentException e) {
            notes.add("内容行的算法不是本系统规范值（拒绝下载／拒绝还原，需人工修数据）：contentId="
                    + candidate.getContentId() + "|hashAlgorithm=" + candidate.getHashAlgorithm());
            return null;
        }
        if (candidate.getDigest() == null || candidate.getDigest().isBlank()) {
            notes.add("内容行缺少摘要（拒绝下载／拒绝还原，需人工修数据）：contentId=" + candidate.getContentId());
            return null;
        }
        return algorithm;
    }

    private static String relativeKey(Path root, Path file) {
        return root.relativize(file).toString().replace('\\', '/');
    }
}
