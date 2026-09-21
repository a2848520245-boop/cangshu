package com.cangshu.catalog;

import com.cangshu.catalog.entity.ContentEntity;
import com.cangshu.catalog.entity.ResourceEntity;
import com.cangshu.catalog.mapper.ContentMapper;
import com.cangshu.catalog.mapper.ResourceMapper;
import com.cangshu.config.CangshuProperties;
import com.cangshu.storage.LockTimeoutException;
import com.cangshu.storage.SegmentLockManager;
import java.time.OffsetDateTime;
import java.time.ZoneOffset;
import java.time.temporal.ChronoUnit;
import java.util.UUID;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Service;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.TransactionDefinition;
import org.springframework.transaction.support.TransactionTemplate;

/**
 * 回收站写入侧（catalog；任务 6；05-接口契约 §3.5、04-架构与计划 §5 ①、06-数据契约 §7／§8）。
 *
 * <p>本类只承担四段动作里的 **① 软删**：读资源 → 取分段锁 → 置删除态并写软删时刻与固定到期时刻。
 * 硬删（到期或显式清空）、还原、GC 与对账属任务 28，不要在这一类里顺手做。
 *
 * <p>三条不可让步的口径：
 *
 * <ul>
 *   <li><b>删除只删引用</b>：软删只改资源行；内容行与物理字节都不动，保护引用计数照样包含这一行
 *       （04 §5 ①、06 §7 读图要点）——因此软删**不触发**内容待回收，字节由 GC 在硬删之后才回收。</li>
 *   <li><b>软删幂等</b>：重复软删**不刷新**首次到期时刻（06 §8）；资源已在回收站时直接返回原值，
 *       不写任何列，避免反复删除无限延长保留期。</li>
 *   <li><b>保留期取配置</b>：默认 7 天、测试可为 0、禁止负数（06 §8、07 §1）。到期只是硬删行的
 *       时间条件，不是删字节的条件。</li>
 * </ul>
 *
 * <p><b>锁的取法</b>：锁键是「算法＋摘要」，而资源行只带 {@code content_id}，因此必须先做一次
 * 锁外读取才能拿到锁键（与上传路径「锁外先算摘要」同形）；**判定与写入全部在锁内完成**——
 * 锁内重读资源行，不使用锁外快照（04 §6）。删除是六类共锁操作之一（04 §6）。
 * 唯一的例外是「已在回收站」的幂等返回：它不产生写入，故不取锁（取锁反而可能让一次无害的
 * 重复删除因等锁超时变成 503）。
 */
@Service
public class TrashService {

    private static final Logger log = LoggerFactory.getLogger(TrashService.class);

    public static final String RESOURCE_STATUS_READY = "READY";
    public static final String RESOURCE_STATUS_DELETED = "DELETED";

    private final SegmentLockManager locks;
    private final ResourceMapper resourceMapper;
    private final ContentMapper contentMapper;
    private final CangshuProperties properties;
    private final TransactionTemplate writeTxn;

    public TrashService(SegmentLockManager locks, ResourceMapper resourceMapper, ContentMapper contentMapper,
            CangshuProperties properties, PlatformTransactionManager transactionManager) {
        this.locks = locks;
        this.resourceMapper = resourceMapper;
        this.contentMapper = contentMapper;
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
            // 已在回收站：幂等返回首次时刻，**不写任何列**（06 §8）。
            // 这里也不取分段锁：本次不产生任何写入，而重复删除若因等锁超时而回 503，是把一次
            // 无害的幂等调用变成失败——与「重复软删不刷新到期时刻」同一目的（06 §8）。
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

        SegmentLockManager.Handle handle;
        try {
            handle = locks.acquire(content.getHashAlgorithm(), content.getDigest());
        } catch (LockTimeoutException e) {
            throw CatalogException.serviceBusy("服务正忙，请稍后重试（等待分段锁超过 "
                    + SegmentLockManager.WAIT_TIMEOUT_SECONDS + " 秒）");
        }
        try (handle) {
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

        OffsetDateTime now = OffsetDateTime.now(ZoneOffset.UTC).truncatedTo(ChronoUnit.MICROS);
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

    private static CatalogException notFound() {
        return new CatalogException(CatalogException.Code.RESOURCE_NOT_FOUND, "资源不存在", null);
    }
}
