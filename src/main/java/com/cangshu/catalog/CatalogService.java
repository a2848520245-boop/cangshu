package com.cangshu.catalog;

import com.cangshu.catalog.entity.ContentConflictEntity;
import com.cangshu.catalog.entity.ContentEntity;
import com.cangshu.catalog.entity.LocationEntity;
import com.cangshu.catalog.entity.ResourceEntity;
import com.cangshu.catalog.mapper.ContentConflictMapper;
import com.cangshu.catalog.mapper.ContentMapper;
import com.cangshu.catalog.mapper.LocationMapper;
import com.cangshu.catalog.mapper.ResourceMapper;
import com.cangshu.common.UuidV7;
import com.cangshu.ingest.StagedUpload;
import com.cangshu.storage.Algorithms;
import com.cangshu.storage.FileStore;
import com.cangshu.storage.LockTimeoutException;
import com.cangshu.storage.SegmentLockManager;
import com.baomidou.mybatisplus.core.toolkit.Wrappers;
import java.nio.file.Path;
import java.time.OffsetDateTime;
import java.time.ZoneOffset;
import java.util.List;
import java.util.UUID;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.dao.DuplicateKeyException;
import org.springframework.stereotype.Service;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.TransactionDefinition;
import org.springframework.transaction.support.TransactionTemplate;

/**
 * 上传写入协议（catalog 模块；04-架构与计划 §4 七分支，任务 3 范围＝A 新建／B 复用／D 大小冲突／
 * E 字节冲突／F 目标键被占／G 并发抢先；C 复活复用依赖内容生命周期状态，属后续任务）。
 *
 * <p>前置顺序恒定：① 流式落临时文件并算摘要（ingest，锁外）→ ② 取分段锁 → ③ 锁内建立
 * REPEATABLE READ 事务快照（必须在取锁之后）→ ④ 按分支处理 → ⑤ 持锁至提交结束。
 * 冲突审计用独立短事务（REQUIRES_NEW）：业务事务回滚后仍保留（06-数据契约 §4）。
 */
@Service
public class CatalogService {

    private static final Logger log = LoggerFactory.getLogger(CatalogService.class);

    static final String STORAGE_BACKEND = "filesystem";
    static final String CONTENT_STATUS_READY = "READY";
    static final String RESOURCE_STATUS_READY = "READY";
    static final String TAGS_EMPTY_JSON = "[]";

    /** 冲突回滚后的重试次数与退避（DEC-T2：重试 2 次，退避 50／100ms）。 */
    static final long[] RETRY_BACKOFF_MILLIS = {50L, 100L};

    private final FileStore files;
    private final SegmentLockManager locks;
    private final ContentMapper contentMapper;
    private final ResourceMapper resourceMapper;
    private final LocationMapper locationMapper;
    private final ContentConflictMapper conflictMapper;
    private final TransactionTemplate writeTxn;
    private final TransactionTemplate auditTxn;

    public CatalogService(FileStore files, SegmentLockManager locks, ContentMapper contentMapper,
            ResourceMapper resourceMapper, LocationMapper locationMapper, ContentConflictMapper conflictMapper,
            PlatformTransactionManager transactionManager) {
        this.files = files;
        this.locks = locks;
        this.contentMapper = contentMapper;
        this.resourceMapper = resourceMapper;
        this.locationMapper = locationMapper;
        this.conflictMapper = conflictMapper;
        this.writeTxn = new TransactionTemplate(transactionManager);
        this.writeTxn.setIsolationLevel(TransactionDefinition.ISOLATION_REPEATABLE_READ);
        this.auditTxn = new TransactionTemplate(transactionManager);
        this.auditTxn.setPropagationBehavior(TransactionDefinition.PROPAGATION_REQUIRES_NEW);
    }

    /** 上传结果：响应组装所需全部字段（对外不暴露 revived 等内部标记——I2）。 */
    public record UploadResult(UUID resourceId, UUID contentId, String name, String mimeType,
            long sizeBytes, String canonicalAlgorithm, String digest, boolean deduplicated,
            OffsetDateTime createdAt) {
    }

    /** 并发抢先／唯一约束挡下后的重试信号（内部控制流；G 分支，重试 2 次）。 */
    private static final class RetryableRaceException extends RuntimeException {
    }

    /**
     * 上传主路径：摘要已在锁外算好；取分段锁后按七分支处理。
     * 临时文件在成功（A 已移动）或终态失败（清理）后不再保留。
     */
    public UploadResult upload(StagedUpload staged, String name, String mimeType) {
        String digest = staged.digest().toLowerCase();
        String storageKey = files.storageKey(Algorithms.CANONICAL_SHA256, digest);
        SegmentLockManager.Handle handle;
        try {
            handle = locks.acquire(Algorithms.CANONICAL_SHA256, digest);
        } catch (LockTimeoutException e) {
            files.deleteTemp(staged.temp());
            throw CatalogException.serviceBusy("服务正忙，请稍后重试（等待分段锁超过 "
                    + SegmentLockManager.WAIT_TIMEOUT_SECONDS + " 秒）");
        }
        try (handle) {
            for (int attempt = 0; ; attempt++) {
                try {
                    return attemptLocked(staged, name, mimeType, digest, storageKey);
                } catch (RetryableRaceException e) {
                    if (attempt >= RETRY_BACKOFF_MILLIS.length) {
                        files.deleteTemp(staged.temp());
                        throw CatalogException.internalError("并发重试次数耗尽，写入未完成（原行原字节未动）");
                    }
                    sleepBackoff(RETRY_BACKOFF_MILLIS[attempt]);
                } catch (DuplicateKeyException e) {
                    if (attempt >= RETRY_BACKOFF_MILLIS.length) {
                        files.deleteTemp(staged.temp());
                        throw CatalogException.internalError("内容唯一约束冲突重试次数耗尽（原行原字节未动）");
                    }
                    sleepBackoff(RETRY_BACKOFF_MILLIS[attempt]);
                } catch (CatalogException e) {
                    files.deleteTemp(staged.temp());
                    throw e;
                }
            }
        }
    }

    /** 锁内一轮分支处理（④）；事务快照在进入本方法的事务开始时建立（取锁之后，③）。 */
    private UploadResult attemptLocked(StagedUpload staged, String name, String mimeType,
            String digest, String storageKey) {
        return writeTxn.execute(status -> {
            List<ContentEntity> rows = selectContentForUpdate(digest);
            if (rows.size() > 1) {
                // 同「算法＋摘要」多条异常记录：拒绝写入并告警，不得任选一条（04 §3、06 §3）。
                log.error("CANGSHU|alert|digest={} 同一算法＋摘要存在 {} 条内容记录，拒绝写入", digest, rows.size());
                throw CatalogException.internalError("同一算法＋摘要存在多条内容记录，拒绝写入并告警");
            }
            if (!rows.isEmpty()) {
                return resolveWithExistingContent(rows.get(0), staged, name, mimeType, digest, storageKey);
            }
            if (files.blobExists(storageKey)) {
                return resolveTargetOccupied(staged, name, mimeType, digest, storageKey);
            }
            return createNew(staged, name, mimeType, digest, storageKey);
        });
    }

    /** 分支 B／D／E：命中既有内容行——先比大小（D），再逐字节（E），两步都在移动之前。 */
    private UploadResult resolveWithExistingContent(ContentEntity existing, StagedUpload staged,
            String name, String mimeType, String digest, String storageKey) {
        if (existing.getSizeBytes() != staged.sizeBytes()) {
            // D 大小冲突：不读取既有文件逐字节比较；写审计 → 409；原行原字节不动。
            recordConflict(digest, existing, staged, null, "SIZE_MISMATCH");
            log.warn("CANGSHU|conflict|reason=SIZE_MISMATCH|digest={}|existing={}|incoming={}",
                    digest, existing.getSizeBytes(), staged.sizeBytes());
            throw CatalogException.conflict("SIZE_MISMATCH", "内容校验冲突：同摘要内容大小不一致");
        }
        String existingKey = soleStorageKeyOf(existing.getId());
        if (!files.blobExists(existingKey)) {
            // 既有内容行存在而字节缺失：缺失字节属最高危（08 故障矩阵），拒绝并留告警（对账属任务 28）。
            log.error("CANGSHU|alert|contentId={} 字节缺失，拒绝复用判定", existing.getId());
            throw CatalogException.internalError("既有内容字节缺失，拒绝写入并告警");
        }
        if (!sameBytes(staged.temp(), existingKey, digest)) {
            // E 字节冲突：写审计 → 409；原行原字节不动。
            recordConflict(digest, existing, staged, existingKey, "BYTE_MISMATCH");
            log.warn("CANGSHU|conflict|reason=BYTE_MISMATCH|digest={}", digest);
            throw CatalogException.conflict("BYTE_MISMATCH", "内容校验冲突：同摘要同大小但逐字节不一致");
        }
        // B 命中复用：不重写字节，只插资源行。
        return insertResourceFor(staged, name, mimeType, existing.getId(), true);
    }

    /** 分支 F：库内无该摘要行而内容地址已有字节——字节相同幂等补齐索引行，不同写审计 409。 */
    private UploadResult resolveTargetOccupied(StagedUpload staged, String name, String mimeType,
            String digest, String storageKey) {
        if (!sameBytes(staged.temp(), storageKey, digest)) {
            recordConflict(digest, null, staged, storageKey, "TARGET_PATH_EXISTS");
            log.warn("CANGSHU|conflict|reason=TARGET_PATH_EXISTS|digest={}", digest);
            throw CatalogException.conflict("TARGET_PATH_EXISTS",
                    "内容校验冲突：目标内容键已被占用且无确实可复用的内容记录");
        }
        return insertContentLocationResource(staged, name, mimeType, digest, storageKey, true);
    }

    /** 分支 A：新建——校验后原子移动（绝不覆盖），插内容＋位置＋资源。 */
    private UploadResult createNew(StagedUpload staged, String name, String mimeType,
            String digest, String storageKey) {
        FileStore.MoveOutcome outcome;
        try {
            outcome = files.moveInto(staged.temp(), storageKey);
        } catch (java.io.IOException e) {
            throw CatalogException.internalError("内容字节移动失败：" + e.getMessage());
        }
        if (outcome == FileStore.MoveOutcome.TARGET_EXISTS) {
            // G 并发抢先：移动落空 → 新事务重验字节后转复用（本轮事务无写入，直接重开）。
            throw new RetryableRaceException();
        }
        try {
            return insertContentLocationResource(staged, name, mimeType, digest, storageKey, false);
        } catch (DuplicateKeyException e) {
            // G：插入被唯一约束挡下 → 新事务重验后转复用（字节已入位，事务回滚不改字节）。
            throw new RetryableRaceException();
        }
    }

    /** 插入内容＋位置＋资源三个行（分支 A／F 复用路径）；deduplicated 表示本次未新增物理字节。 */
    private UploadResult insertContentLocationResource(StagedUpload staged, String name, String mimeType,
            String digest, String storageKey, boolean deduplicated) {
        OffsetDateTime now = OffsetDateTime.now(ZoneOffset.UTC).truncatedTo(java.time.temporal.ChronoUnit.MICROS);
        UUID contentId = UuidV7.generate();
        ContentEntity content = new ContentEntity();
        content.setId(contentId);
        content.setHashAlgorithm(Algorithms.CANONICAL_SHA256);
        content.setDigest(digest);
        content.setSizeBytes(staged.sizeBytes());
        content.setStatus(CONTENT_STATUS_READY);
        content.setCreatedAt(now);
        contentMapper.insert(content);

        LocationEntity location = new LocationEntity();
        location.setId(UuidV7.generate());
        location.setContentId(contentId);
        location.setStorageBackend(STORAGE_BACKEND);
        location.setStorageKey(storageKey);
        locationMapper.insert(location);

        UUID resourceId = UuidV7.generate();
        ResourceEntity resource = new ResourceEntity();
        resource.setId(resourceId);
        resource.setName(name);
        resource.setSizeBytes(staged.sizeBytes());
        resource.setMimeType(mimeType);
        resource.setContentId(contentId);
        resource.setTags(TAGS_EMPTY_JSON);
        resource.setStatus(RESOURCE_STATUS_READY);
        resource.setCreatedAt(now);
        resource.setUpdatedAt(now);
        resourceMapper.insert(resource);

        // A 路径临时文件已被移动（deleteIfExists 无害）；F 补齐路径显式清理临时字节。
        files.deleteTemp(staged.temp());
        return new UploadResult(resourceId, contentId, name, mimeType, staged.sizeBytes(),
                Algorithms.CANONICAL_SHA256, digest, deduplicated, now);
    }

    /** 分支 B：只插资源行，复用既有内容与字节。 */
    private UploadResult insertResourceFor(StagedUpload staged, String name, String mimeType,
            UUID contentId, boolean deduplicated) {
        OffsetDateTime now = OffsetDateTime.now(ZoneOffset.UTC).truncatedTo(java.time.temporal.ChronoUnit.MICROS);
        UUID resourceId = UuidV7.generate();
        ResourceEntity resource = new ResourceEntity();
        resource.setId(resourceId);
        resource.setName(name);
        resource.setSizeBytes(staged.sizeBytes());
        resource.setMimeType(mimeType);
        resource.setContentId(contentId);
        resource.setTags(TAGS_EMPTY_JSON);
        resource.setStatus(RESOURCE_STATUS_READY);
        resource.setCreatedAt(now);
        resource.setUpdatedAt(now);
        resourceMapper.insert(resource);
        files.deleteTemp(staged.temp());
        return new UploadResult(resourceId, contentId, name, mimeType, staged.sizeBytes(),
                Algorithms.CANONICAL_SHA256, staged.digest(), deduplicated, now);
    }

    /**
     * 冲突审计（独立短事务，REQUIRES_NEW）：业务事务回滚后仍保留；审计写入失败显式报错（06 §4）。
     * 既有侧三项仅在确实存在时填写，不得填伪 ID（DEC-I5）。
     */
    private void recordConflict(String digest, ContentEntity existing, StagedUpload staged,
            String existingStorageKey, String reason) {
        auditTxn.executeWithoutResult(status -> {
            ContentConflictEntity row = new ContentConflictEntity();
            row.setId(UuidV7.generate());
            row.setHashAlgorithm(Algorithms.CANONICAL_SHA256);
            row.setDigest(digest);
            if (existing != null) {
                row.setExistingContentId(existing.getId());
                row.setExistingSizeBytes(existing.getSizeBytes());
            }
            row.setExistingStorageKey(existingStorageKey);
            row.setIncomingSizeBytes(staged.sizeBytes());
            row.setIncomingStorageKey(files.tempKey(staged.temp()));
            row.setReason(reason);
            row.setCreatedAt(OffsetDateTime.now(ZoneOffset.UTC).truncatedTo(java.time.temporal.ChronoUnit.MICROS));
            conflictMapper.insert(row);
        });
    }

    /** 锁内按「算法＋摘要」查询内容行（走 idx_content_digest；FOR UPDATE 串行化跨实例复用判定）。 */
    private List<ContentEntity> selectContentForUpdate(String digest) {
        return contentMapper.selectList(Wrappers.<ContentEntity>lambdaQuery()
                .eq(ContentEntity::getHashAlgorithm, Algorithms.CANONICAL_SHA256)
                .eq(ContentEntity::getDigest, digest)
                .last("FOR UPDATE"));
    }

    private String soleStorageKeyOf(UUID contentId) {
        List<LocationEntity> locations = locationMapper.selectList(
                Wrappers.<LocationEntity>lambdaQuery().eq(LocationEntity::getContentId, contentId));
        if (locations.size() != 1) {
            throw CatalogException.internalError("内容 " + contentId + " 的位置记录数异常：" + locations.size());
        }
        return locations.get(0).getStorageKey();
    }

    private void sleepBackoff(long millis) {
        try {
            Thread.sleep(millis);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            throw CatalogException.serviceBusy("服务正忙，请稍后重试（取锁被中断）");
        }
    }

    /** 逐字节比较；IO 异常视为不可判定，显式报错并留故障事件（不静默当作「不一致」）。 */
    private boolean sameBytes(Path temp, String storageKey, String digest) {
        try {
            return files.sameBytes(temp, storageKey);
        } catch (java.io.IOException e) {
            log.error("CANGSHU|alert|digest={} 逐字节比较 IO 失败", digest, e);
            throw CatalogException.internalError("逐字节比较失败：" + e.getMessage());
        }
    }
}
