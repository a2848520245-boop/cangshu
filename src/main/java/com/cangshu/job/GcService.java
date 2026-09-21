package com.cangshu.job;

import com.baomidou.mybatisplus.core.toolkit.Wrappers;
import com.cangshu.catalog.ProtectionReferenceService;
import com.cangshu.catalog.TrashService;
import com.cangshu.catalog.entity.ContentEntity;
import com.cangshu.catalog.entity.LocationEntity;
import com.cangshu.catalog.mapper.ContentMapper;
import com.cangshu.catalog.mapper.LocationMapper;
import com.cangshu.storage.FileStore;
import com.cangshu.storage.SegmentLockManager;
import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.OffsetDateTime;
import java.time.ZoneOffset;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.Set;
import java.util.UUID;
import java.util.concurrent.ConcurrentHashMap;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Service;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.support.TransactionTemplate;

/**
 * GC 回收作业（job 模块，任务 28；04-架构与计划 §5 ③④、§7、07-运行手册 §6）。
 *
 * <p>一次运行＝三件事，顺序不可颠倒：
 *
 * <ol>
 *   <li><b>到期清空</b>：把回收站里 {@code expire_at <= now()} 的行硬删（复用
 *       {@link TrashService#hardDelete}），删完实时查引用数、归零才置待回收。</li>
 *   <li><b>回收队列三段提交</b>（每个内容身份）：段一锁内重读状态与保护引用数 → 置 {@code RECLAIMING}
 *       ＋ 删位置行（独立提交）；段二幂等删字节（文件已缺＝成功）；段三置 {@code RECLAIMED}（独立提交）。</li>
 *   <li><b>告警</b>：同一对象连续两个 GC 周期仍为 {@code RECLAIMING}；字节与内容地址不符
 *       （{@code BYTE_MISMATCH}）立即告警并**停止本轮删除**，字节不盲删。</li>
 * </ol>
 *
 * <p>关键设计：分段锁在**三段全程持有**（04 §6「持锁至文件操作与数据库提交结束」）。若在段一提交后
 * 放锁，复活路径（04 §4 分支 C）可能在段二之前把内容置回就绪，段二就会删掉一份已被引用的字节。
 *
 * <p>中断续接（04 §5）：段一提交前被杀 → 保持待回收；段二被杀 → 状态为回收中，字节可能已删或未删，
 * 重扫时两种都幂等通过；段三被杀 → 保持回收中，下次重扫补齐。
 */
@Service
public class GcService {

    private static final Logger log = LoggerFactory.getLogger(GcService.class);

    static final String CONTENT_STATUS_RECLAIM_PENDING = "RECLAIM_PENDING";
    static final String CONTENT_STATUS_RECLAIMING = "RECLAIMING";
    static final String CONTENT_STATUS_RECLAIMED = "RECLAIMED";

    private final TrashService trash;
    private final ContentMapper contentMapper;
    private final LocationMapper locationMapper;
    private final ProtectionReferenceService references;
    private final FileStore files;
    private final SegmentLockManager locks;
    private final TransactionTemplate txn;

    /** 上一轮扫描结束时仍停在回收中的对象（用于「连续两个周期」告警；单写者门保证只有一个写者）。 */
    private final Set<UUID> lastCycleReclaiming = ConcurrentHashMap.newKeySet();

    public GcService(TrashService trash, ContentMapper contentMapper, LocationMapper locationMapper,
            ProtectionReferenceService references, FileStore files, SegmentLockManager locks,
            PlatformTransactionManager transactionManager) {
        this.trash = trash;
        this.contentMapper = contentMapper;
        this.locationMapper = locationMapper;
        this.references = references;
        this.files = files;
        this.locks = locks;
        this.txn = new TransactionTemplate(transactionManager);
    }

    /** 一轮 GC 的结果（结构化摘要；{@link #needsAttention()} 为真时须人工介入，进程须以非零结束）。 */
    public record GcRunResult(OffsetDateTime startedAt, int expiredHardDeleted, int reclaimed,
            int restoredToReady, int byteMismatch, int staleReclaiming, List<String> notes) {

        public boolean needsAttention() {
            return byteMismatch > 0 || staleReclaiming > 0 || !notes.isEmpty();
        }

        public String summary() {
            return "gc|expiredHardDeleted=" + expiredHardDeleted + "|reclaimed=" + reclaimed
                    + "|restoredToReady=" + restoredToReady + "|byteMismatch=" + byteMismatch
                    + "|staleReclaiming=" + staleReclaiming + "|needsAttention=" + needsAttention();
        }
    }

    public GcRunResult runOnce() {
        OffsetDateTime startedAt = OffsetDateTime.now(ZoneOffset.UTC);
        List<String> notes = new ArrayList<>();

        // ① 到期清空：回收站里已到期的行硬删（05 §3.5「到期或手动清空才硬删」）
        int expiredHardDeleted = trash.hardDelete(TrashService.HardDeleteScope.EXPIRED);

        // ② 回收队列：待回收 ＋ 上一轮中断留下的回收中
        List<UUID> candidates = new ArrayList<>();
        candidates.addAll(contentIdsWithStatus(CONTENT_STATUS_RECLAIM_PENDING));
        candidates.addAll(contentIdsWithStatus(CONTENT_STATUS_RECLAIMING));

        int reclaimed = 0;
        int restoredToReady = 0;
        int byteMismatch = 0;
        boolean stopDeleting = false;
        for (UUID contentId : candidates) {
            if (stopDeleting) {
                break;
            }
            ContentEntity preview = contentMapper.selectById(contentId);
            if (preview == null) {
                continue;
            }
            try (SegmentLockManager.Handle handle =
                    locks.acquire(preview.getHashAlgorithm(), preview.getDigest())) {
                Phase1 phase1 = txn.execute(status -> enterReclaiming(contentId));
                if (phase1 == null || !phase1.proceed()) {
                    if (phase1 != null) {
                        if (phase1.restored()) {
                            restoredToReady++;
                        } else if (phase1.attention()) {
                            notes.add("contentId=" + contentId + "：" + phase1.note());
                        }
                    }
                    continue;
                }
                ByteOutcome bytes = deleteBytes(preview, phase1.storageKey());
                if (bytes == ByteOutcome.BYTE_MISMATCH) {
                    byteMismatch++;
                    notes.add("contentId=" + contentId + " 字节与内容地址不符（BYTE_MISMATCH）：不删除、不置已回收，"
                            + "立即告警并停止本轮删除");
                    stopDeleting = true;   // 「立即告警并停止删除」：本轮不再删任何字节
                    continue;
                }
                if (bytes == ByteOutcome.IO_FAILURE) {
                    notes.add("contentId=" + contentId + " 删字节 IO 失败：保持回收中，下次重扫续接");
                    continue;
                }
                txn.executeWithoutResult(status -> markReclaimed(contentId));
                reclaimed++;
            }
        }

        // ③ 连续两个 GC 周期仍为回收中 → 告警（阈值＝2 个 GC 周期，07 §6）
        Set<UUID> stillReclaiming = new HashSet<>(contentIdsWithStatus(CONTENT_STATUS_RECLAIMING));
        Set<UUID> stale = new HashSet<>(stillReclaiming);
        stale.retainAll(lastCycleReclaiming);
        if (!stale.isEmpty()) {
            notes.add("连续两个 GC 周期仍为 RECLAIMING 的对象：" + stale.size() + " 个（需人工介入）");
        }
        lastCycleReclaiming.clear();
        lastCycleReclaiming.addAll(stillReclaiming);

        GcRunResult result = new GcRunResult(startedAt, expiredHardDeleted, reclaimed, restoredToReady,
                byteMismatch, stale.size(), notes);
        log.info("CANGSHU|job|gc|{}", result.summary());
        notes.forEach(note -> log.warn("CANGSHU|job|gc|alert|{}", note));
        return result;
    }

    // ────────────────────────── 段一 ──────────────────────────

    private Phase1 enterReclaiming(UUID contentId) {
        ContentEntity content = contentMapper.selectById(contentId);
        if (content == null) {
            return Phase1.skip("内容行已不存在");
        }
        String status = content.getStatus();
        if (!CONTENT_STATUS_RECLAIM_PENDING.equals(status) && !CONTENT_STATUS_RECLAIMING.equals(status)) {
            return Phase1.skip("状态已变：" + status);
        }
        long protecting = references.countProtecting(contentId);
        if (protecting > 0) {
            if (CONTENT_STATUS_RECLAIM_PENDING.equals(status)) {
                // 引用恢复：待回收内容被重新引用 → 回就绪（06 §7）；字节一根不动
                references.syncReclaimState(contentId);
                log.info("CANGSHU|job|gc|contentId={}|restoredToReady|protecting={}", contentId, protecting);
                return Phase1.restored("引用恢复，内容回到就绪");
            }
            // 已是回收中却仍有引用：绝不删字节（那会毁掉一条可读资源）
            return Phase1.attention("状态为 RECLAIMING 但仍有 " + protecting + " 条保护引用，拒绝删字节");
        }

        String expectedKey = files.storageKey(content.getHashAlgorithm(), content.getDigest());
        List<LocationEntity> locations = locationMapper.selectList(
                Wrappers.<LocationEntity>lambdaQuery().eq(LocationEntity::getContentId, contentId));
        if (locations.size() > 1
                || (locations.size() == 1 && !expectedKey.equals(locations.get(0).getStorageKey()))) {
            return Phase1.attention("位置记录异常（" + locations.size() + " 条）或位置键与内容身份不符，拒绝删字节");
        }
        if (!locations.isEmpty()) {
            // 段一的删除动作：位置行先走，字节后走（06 §8 外键顺序）
            locationMapper.delete(Wrappers.<LocationEntity>lambdaQuery().eq(LocationEntity::getContentId, contentId));
        }
        if (CONTENT_STATUS_RECLAIM_PENDING.equals(status)) {
            contentMapper.update(null, Wrappers.<ContentEntity>lambdaUpdate()
                    .eq(ContentEntity::getId, contentId)
                    .set(ContentEntity::getStatus, CONTENT_STATUS_RECLAIMING));
        }
        return Phase1.ok(expectedKey);
    }

    // ────────────────────────── 段二 ──────────────────────────

    /** 幂等删字节：文件已缺＝成功；字节与内容地址不符＝BYTE_MISMATCH（不删、不置已回收）。 */
    private ByteOutcome deleteBytes(ContentEntity content, String storageKey) {
        Path blob = files.blobPath(storageKey);
        if (!Files.isRegularFile(blob)) {
            return ByteOutcome.MISSING_OK;
        }
        try {
            String actual = files.sha256Hex(blob);
            if (!actual.equalsIgnoreCase(content.getDigest())) {
                log.error("CANGSHU|alert|contentId={} BYTE_MISMATCH：盘上 {} ≠ 内容身份 {}，不删除、不置已回收",
                        content.getId(), actual, content.getDigest());
                return ByteOutcome.BYTE_MISMATCH;
            }
            files.deleteBlob(storageKey);
            return ByteOutcome.DELETED;
        } catch (IOException e) {
            log.error("CANGSHU|alert|contentId={} 删字节失败：{}", content.getId(), e.getMessage());
            return ByteOutcome.IO_FAILURE;
        }
    }

    // ────────────────────────── 段三 ──────────────────────────

    private void markReclaimed(UUID contentId) {
        contentMapper.update(null, Wrappers.<ContentEntity>lambdaUpdate()
                .eq(ContentEntity::getId, contentId)
                .set(ContentEntity::getStatus, CONTENT_STATUS_RECLAIMED));
        log.info("CANGSHU|job|gc|contentId={}|reclaimed", contentId);
    }

    private List<UUID> contentIdsWithStatus(String status) {
        return contentMapper.selectList(Wrappers.<ContentEntity>lambdaQuery()
                        .eq(ContentEntity::getStatus, status)
                        .orderByAsc(ContentEntity::getId))
                .stream()
                .map(ContentEntity::getId)
                .toList();
    }

    /** 段一结果：是否继续删字节、是否「回就绪」、是否需告警、以及内容地址键。 */
    private record Phase1(boolean proceed, boolean restored, boolean attention, String storageKey, String note) {

        static Phase1 ok(String storageKey) {
            return new Phase1(true, false, false, storageKey, null);
        }

        static Phase1 skip(String note) {
            return new Phase1(false, false, false, null, note);
        }

        static Phase1 restored(String note) {
            return new Phase1(false, true, false, null, note);
        }

        static Phase1 attention(String note) {
            return new Phase1(false, false, true, null, note);
        }
    }

    private enum ByteOutcome {
        DELETED,
        MISSING_OK,
        BYTE_MISMATCH,
        IO_FAILURE
    }
}
