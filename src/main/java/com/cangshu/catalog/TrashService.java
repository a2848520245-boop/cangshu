package com.cangshu.catalog;

import com.baomidou.mybatisplus.core.toolkit.Wrappers;
import com.cangshu.catalog.entity.ContentEntity;
import com.cangshu.catalog.entity.LocationEntity;
import com.cangshu.catalog.entity.ResourceEntity;
import com.cangshu.catalog.mapper.ContentMapper;
import com.cangshu.catalog.mapper.LocationMapper;
import com.cangshu.catalog.mapper.ResourceMapper;
import com.cangshu.catalog.mapper.TrashRow;
import com.cangshu.config.CangshuProperties;
import com.cangshu.storage.FileStore;
import com.cangshu.storage.LockTimeoutException;
import com.cangshu.storage.SegmentLockManager;
import java.io.IOException;
import java.time.OffsetDateTime;
import java.time.ZoneOffset;
import java.time.temporal.ChronoUnit;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Service;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.TransactionDefinition;
import org.springframework.transaction.support.TransactionTemplate;

/**
 * 回收站写入侧（catalog；任务 6 与任务 28；05-接口契约 §3.5–§3.8、04-架构与计划 §5 ①②、
 * 06-数据契约 §7／§8）。
 *
 * <p>承担四段动作里的 **① 软删** 与 **② 硬删**（到期或显式清空）。**③ GC 三段提交与 ④ 对账
 * 不在这里**——它们是后台作业，属 `job` 模块（04 §1「job：GC 回收、到期清空、对账」）；
 * 本类只提供它们要复用的硬删原语 {@link #hardDelete(HardDeleteScope)}。
 *
 * <p>四条不可让步的口径：
 *
 * <ul>
 *   <li><b>删除只删引用</b>：软删只改资源行；内容行与物理字节都不动，保护引用计数照样包含这一行
 *       （04 §5 ①、06 §7 读图要点）——因此软删**不触发**内容待回收，字节由 GC 在硬删之后才回收。</li>
 *   <li><b>硬删后实时查引用数</b>：删完资源行立刻按内容身份查保护引用数，**归零才**把内容置为
 *       {@code RECLAIM_PENDING} 交 GC（04 §5 ②、06 §8）；计数不走本类自算，一律经
 *       {@link ProtectionReferenceService}，避免第二套口径。</li>
 *   <li><b>软删幂等</b>：重复软删**不刷新**首次到期时刻（06 §8）；资源已在回收站时直接返回原值、
 *       一行不写。该分支不取锁——本次不产生写入，而取锁可能让一次无害的重复删除因等锁超时变成 503。</li>
 *   <li><b>清空须显式确认</b>：未带确认时返回 400 且**不删除任何内容**（05 §3.8、08 §5）。</li>
 * </ul>
 *
 * <p><b>锁的取法</b>：锁键是「算法＋摘要」，而资源行只带 {@code content_id}，因此必须先做一次
 * 锁外读取才能拿到锁键（与上传路径「锁外先算摘要」同形）；**判定与写入全部在锁内完成**——
 * 锁内重读资源行，不使用锁外快照（04 §6）。删除是六类共锁操作之一（04 §6）。
 */
@Service
public class TrashService {

    private static final Logger log = LoggerFactory.getLogger(TrashService.class);

    public static final String RESOURCE_STATUS_READY = "READY";
    public static final String RESOURCE_STATUS_DELETED = "DELETED";

    /** 硬删范围：到期（GC 触发）或全部（显式清空）（04 §5 ②）。 */
    public enum HardDeleteScope {
        EXPIRED,
        ALL
    }

    private final SegmentLockManager locks;
    private final ResourceMapper resourceMapper;
    private final ContentMapper contentMapper;
    private final LocationMapper locationMapper;
    private final FileStore files;
    private final ProtectionReferenceService references;
    private final CangshuProperties properties;
    private final TransactionTemplate writeTxn;

    public TrashService(SegmentLockManager locks, ResourceMapper resourceMapper, ContentMapper contentMapper,
            LocationMapper locationMapper, FileStore files, ProtectionReferenceService references,
            CangshuProperties properties, PlatformTransactionManager transactionManager) {
        this.locks = locks;
        this.resourceMapper = resourceMapper;
        this.contentMapper = contentMapper;
        this.locationMapper = locationMapper;
        this.files = files;
        this.references = references;
        this.properties = properties;
        this.writeTxn = new TransactionTemplate(transactionManager);
        this.writeTxn.setIsolationLevel(TransactionDefinition.ISOLATION_REPEATABLE_READ);
    }

    /**
     * 软删结果：留痕首次软删时刻与固定到期时刻，供调用方、日志与测试断言。
     *
     * @param alreadyInTrash 本次是幂等命中（资源本就在回收站），未改写任何列
     */
    public record SoftDeleteOutcome(UUID resourceId, OffsetDateTime deletedAt, OffsetDateTime expireAt,
            boolean alreadyInTrash) {
    }

    /** 还原结果：{@code changed=false} 表示资源本就在活跃列表（幂等无操作）。 */
    public record RestoreOutcome(UUID resourceId, boolean changed) {
    }

    /** 清空结果：{@code deletedCount} 即契约 §3.8 响应体的唯一字段。 */
    public record EmptyTrashOutcome(int deletedCount) {
    }

    // ────────────────────────── ① 软删 ──────────────────────────

    /**
     * 软删资源：置 {@code DELETED} 并写 {@code deletedAt} / {@code expireAt}（05 §3.5）。
     * 资源不存在或已被硬删 → 404 {@code RESOURCE_NOT_FOUND}；重复软删幂等 → 返回首次时刻。
     */
    public SoftDeleteOutcome softDelete(UUID resourceId) {
        ResourceEntity preview = resourceMapper.selectById(resourceId);
        if (preview == null) {
            throw notFound();
        }
        if (RESOURCE_STATUS_DELETED.equals(preview.getStatus())) {
            // 已在回收站：幂等返回首次时刻，**不写任何列**，也不取锁（06 §8）。
            log.info("CANGSHU|trash|resourceId={}|softDelete=idempotent|expireAt={}",
                    resourceId, preview.getExpireAt());
            return new SoftDeleteOutcome(resourceId, preview.getDeletedAt(), preview.getExpireAt(), true);
        }

        ContentEntity content = contentMapper.selectById(preview.getContentId());
        if (content == null) {
            // resource.content_id 有外键约束，内容行缺失属数据异常（04 §3 同类处置：告警，不静默）。
            log.error("CANGSHU|alert|resourceId={} 内容行缺失（contentId={}），拒绝软删",
                    resourceId, preview.getContentId());
            throw CatalogException.internalError("资源的内容行缺失，拒绝软删并告警");
        }

        try (SegmentLockManager.Handle handle = acquireOrBusy(content.getHashAlgorithm(), content.getDigest())) {
            return writeTxn.execute(status -> softDeleteLocked(resourceId));
        }
    }

    /** 锁内一轮：重读资源行后决定是幂等返回还是置删除态（04 §6：锁内禁止使用锁外快照）。 */
    private SoftDeleteOutcome softDeleteLocked(UUID resourceId) {
        ResourceEntity resource = resourceMapper.selectById(resourceId);
        if (resource == null) {
            throw notFound();
        }
        if (RESOURCE_STATUS_DELETED.equals(resource.getStatus())) {
            log.info("CANGSHU|trash|resourceId={}|softDelete=idempotent|expireAt={}",
                    resourceId, resource.getExpireAt());
            return new SoftDeleteOutcome(resourceId, resource.getDeletedAt(), resource.getExpireAt(), true);
        }
        if (!RESOURCE_STATUS_READY.equals(resource.getStatus())) {
            // 06 §7 的资源状态转换里没有 PENDING／FAILED → DELETED；本版资源的落库态只有 READY／DELETED，
            // 出现其他态属数据异常：拒绝并告警，不把它当「可删」悄悄改掉。
            log.error("CANGSHU|alert|resourceId={} 状态 {} 不在可软删范围（06 §7），拒绝软删",
                    resourceId, resource.getStatus());
            throw CatalogException.internalError("资源状态不允许软删：" + resource.getStatus());
        }

        OffsetDateTime now = now();
        OffsetDateTime expireAt = now.plus(properties.getTrash().getRetention());
        ResourceEntity patch = new ResourceEntity();
        patch.setId(resourceId);
        patch.setStatus(RESOURCE_STATUS_DELETED);
        patch.setDeletedAt(now);
        patch.setExpireAt(expireAt);
        patch.setUpdatedAt(now);
        resourceMapper.updateById(patch);

        log.info("CANGSHU|trash|resourceId={}|softDelete=applied|deletedAt={}|expireAt={}",
                resourceId, now, expireAt);
        return new SoftDeleteOutcome(resourceId, now, expireAt, false);
    }

    // ────────────────────────── ② 硬删 ──────────────────────────

    /**
     * 显式清空回收站（05 §3.8）：**未带显式确认即 400 且不删除任何内容**；确认后只硬删回收站中的
     * 目标行与其引用，引用归零的内容才置待回收并交 GC 删字节——**没有第二次保留期**。
     */
    public EmptyTrashOutcome emptyTrash(boolean confirm) {
        if (!confirm) {
            throw CatalogException.invalidArgument(
                    "清空回收站需要显式确认（confirm=true）；未确认时不删除任何内容（05 §3.8）");
        }
        return new EmptyTrashOutcome(hardDelete(HardDeleteScope.ALL));
    }

    /**
     * 硬删原语（04 §5 ②）：按内容身份分组 → **逐组取一次分段锁** → 删资源行 → 实时查保护引用数，
     * 归零即置 {@code RECLAIM_PENDING} 交 GC。返回实际删除的资源行数。
     *
     * <p>分组的意义：一次清空／一次到期扫描通常涉及少量内容与大量资源行；按内容取锁既满足
     * 04 §6 的「六类共锁」，又不必为每一行反复抢锁。
     */
    public int hardDelete(HardDeleteScope scope) {
        List<TrashRow> rows = scope == HardDeleteScope.EXPIRED
                ? resourceMapper.findExpiredTrashRows()
                : resourceMapper.findAllTrashRows();
        if (rows.isEmpty()) {
            return 0;
        }
        Map<UUID, List<TrashRow>> byContent = new LinkedHashMap<>();
        for (TrashRow row : rows) {
            byContent.computeIfAbsent(row.getContentId(), key -> new ArrayList<>()).add(row);
        }
        int deleted = 0;
        for (List<TrashRow> group : byContent.values()) {
            TrashRow head = group.get(0);
            List<UUID> ids = group.stream().map(TrashRow::getResourceId).toList();
            try (SegmentLockManager.Handle handle = acquireOrBusy(head.getHashAlgorithm(), head.getDigest())) {
                deleted += writeTxn.execute(status -> hardDeleteLocked(head.getContentId(), ids));
            }
        }
        log.info("CANGSHU|trash|hardDelete|scope={}|deletedCount={}", scope, deleted);
        return deleted;
    }

    private int hardDeleteLocked(UUID contentId, List<UUID> resourceIds) {
        int deleted = resourceMapper.delete(
                Wrappers.<ResourceEntity>lambdaQuery().in(ResourceEntity::getId, resourceIds));
        // 删资源行后**实时**查引用数（不查缓存列）：归零才置待回收（04 §5 ②、06 §8）
        ProtectionReferenceService.SyncOutcome sync = references.syncReclaimState(contentId);
        log.info("CANGSHU|trash|hardDelete|contentId={}|deletedRows={}|protecting={}|contentStatus={}",
                contentId, deleted, sync.protectingCount(), sync.statusAfter());
        return deleted;
    }

    // ────────────────────────── 还原 ──────────────────────────

    /**
     * 还原资源（05 §3.7）：清除 {@code deletedAt} / {@code expireAt}，回到活跃列表。
     * 目标已被硬删（已清空或已到期回收）→ 404 {@code RESOURCE_NOT_FOUND}；已在活跃列表 → 幂等无操作。
     *
     * <p>字节缺失时**拒绝还原**（08 §4 故障矩阵把「库内就绪行但字节不存在」列为最高危：用户以为
     * 文件在却读不到）：先把资源放回活跃列表、再发现读不到，是个自相矛盾的中间态；因此先校验位置行
     * 与盘上字节，再改状态，并告警。
     *
     * <p>还原是「保护引用恢复」的一种：改完状态后按内容身份重新计数，{@code RECLAIM_PENDING}
     * 会因引用数 &gt; 0 回到就绪（06 §7、{@link ProtectionReferenceService}）。
     */
    public RestoreOutcome restore(UUID resourceId) {
        ResourceEntity preview = resourceMapper.selectById(resourceId);
        if (preview == null) {
            throw notFound();
        }
        ContentEntity content = contentMapper.selectById(preview.getContentId());
        if (content == null) {
            log.error("CANGSHU|alert|resourceId={} 内容行缺失（contentId={}），拒绝还原",
                    resourceId, preview.getContentId());
            throw CatalogException.internalError("资源的内容行缺失，拒绝还原并告警");
        }
        try (SegmentLockManager.Handle handle = acquireOrBusy(content.getHashAlgorithm(), content.getDigest())) {
            return writeTxn.execute(status -> restoreLocked(resourceId, content));
        }
    }

    private RestoreOutcome restoreLocked(UUID resourceId, ContentEntity content) {
        ResourceEntity resource = resourceMapper.selectById(resourceId);
        if (resource == null) {
            throw notFound();
        }
        if (RESOURCE_STATUS_READY.equals(resource.getStatus())) {
            log.info("CANGSHU|trash|resourceId={}|restore=alreadyActive", resourceId);
            return new RestoreOutcome(resourceId, false);
        }
        if (!RESOURCE_STATUS_DELETED.equals(resource.getStatus())) {
            log.error("CANGSHU|alert|resourceId={} 状态 {} 不可还原（06 §7 无此转换）",
                    resourceId, resource.getStatus());
            throw CatalogException.internalError("资源状态不允许还原：" + resource.getStatus());
        }
        assertBytesRestorable(resourceId, content);

        OffsetDateTime now = now();
        // 两个时间戳必须真正置空：MyBatis-Plus 的 updateById 会跳过 null 字段，故这里显式 set(null)。
        resourceMapper.update(null, Wrappers.<ResourceEntity>lambdaUpdate()
                .eq(ResourceEntity::getId, resourceId)
                .set(ResourceEntity::getStatus, RESOURCE_STATUS_READY)
                .set(ResourceEntity::getDeletedAt, null)
                .set(ResourceEntity::getExpireAt, null)
                .set(ResourceEntity::getUpdatedAt, now));
        ProtectionReferenceService.SyncOutcome sync = references.syncReclaimState(content.getId());
        log.info("CANGSHU|trash|resourceId={}|restore=applied|protecting={}|contentStatus={}",
                resourceId, sync.protectingCount(), sync.statusAfter());
        return new RestoreOutcome(resourceId, true);
    }

    /** 还原前置校验：位置行唯一且字节在、大小与内容身份一致（不一致即告警拒止，不放行不可读的活跃行）。 */
    private void assertBytesRestorable(UUID resourceId, ContentEntity content) {
        List<LocationEntity> locations = locationMapper.selectList(
                Wrappers.<LocationEntity>lambdaQuery().eq(LocationEntity::getContentId, content.getId()));
        if (locations.size() != 1) {
            log.error("CANGSHU|alert|resourceId={} contentId={} 位置记录数异常：{}，拒绝还原",
                    resourceId, content.getId(), locations.size());
            throw CatalogException.internalError("内容的位置记录数异常，拒绝还原并告警");
        }
        String storageKey = locations.get(0).getStorageKey();
        if (!files.blobExists(storageKey)) {
            log.error("CANGSHU|alert|resourceId={} contentId={} 字节缺失（存储键 {}），拒绝还原",
                    resourceId, content.getId(), storageKey);
            throw CatalogException.internalError("内容字节缺失，拒绝还原并告警");
        }
        long onDisk;
        try {
            onDisk = files.blobSize(storageKey);
        } catch (IOException e) {
            log.error("CANGSHU|alert|resourceId={} 读取字节大小失败，拒绝还原", resourceId, e);
            throw CatalogException.internalError("读取内容字节失败，拒绝还原并告警");
        }
        if (onDisk != content.getSizeBytes()) {
            log.error("CANGSHU|alert|resourceId={} 字节大小与内容身份不符（盘上 {} / 身份 {}），拒绝还原",
                    resourceId, onDisk, content.getSizeBytes());
            throw CatalogException.internalError("内容字节大小与内容身份不符，拒绝还原并告警");
        }
    }

    // ────────────────────────── 夹具 ──────────────────────────

    private SegmentLockManager.Handle acquireOrBusy(String canonicalAlgorithm, String digest) {
        try {
            return locks.acquire(canonicalAlgorithm, digest);
        } catch (LockTimeoutException e) {
            throw CatalogException.serviceBusy("服务正忙，请稍后重试（等待分段锁超过 "
                    + SegmentLockManager.WAIT_TIMEOUT_SECONDS + " 秒）");
        }
    }

    private static OffsetDateTime now() {
        return OffsetDateTime.now(ZoneOffset.UTC).truncatedTo(ChronoUnit.MICROS);
    }

    private static CatalogException notFound() {
        return new CatalogException(CatalogException.Code.RESOURCE_NOT_FOUND, "资源不存在", null);
    }
}
