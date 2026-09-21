package com.cangshu.catalog;

import com.baomidou.mybatisplus.core.toolkit.Wrappers;
import com.cangshu.catalog.entity.ContentEntity;
import com.cangshu.catalog.entity.ResourceEntity;
import com.cangshu.catalog.mapper.ContentMapper;
import com.cangshu.catalog.mapper.ResourceMapper;
import java.util.UUID;
import org.springframework.stereotype.Service;

/**
 * 保护引用语义（catalog；任务 26／DEC-T1；06-数据契约 §8「保护引用计数」、§7 状态转换；
 * 04-架构与计划 §5 ②「硬删」与 §6「六类共锁」）。
 *
 * <p><b>实时计数，不加冗余列</b>：引用数按 {@code resource.content_id} 索引（{@code idx_resource_content_id}）
 * 实查，不加计数列、不加唯一约束（06 §8）。<b>保护引用包含回收站中的行</b>——软删只是把资源
 * 标记为「在回收站里」，行还在、引用还算数（04 §5 ①、06 §7 读图要点），因此计数不过滤
 * {@code status}，也不看 {@code deleted_at}。
 *
 * <p><b>归零才置待回收</b>：只有引用数＝0 且内容为就绪态时，才把内容置为 {@code RECLAIM_PENDING}，
 * 交给 GC 异步删字节（05 §3.5：删除只删引用，物理字节由 GC 删）。反向地，引用数恢复为 &gt;0 且内容
 * 停在 {@code RECLAIM_PENDING} 时回到 {@code READY}（06 §7 的 {@code RECLAIM_PENDING → READY}）。
 *
 * <p><b>调用约定</b>：必须在持分段锁的事务内调用（04 §5 ②「删资源行后实时查引用数」位于锁内，
 * §6 要求「锁内禁止使用锁外快照」）。本类不自建事务，随调用方的事务边界提交。
 */
@Service
public class ProtectionReferenceService {

    /** 内容就绪态：只有它会被归零推入待回收（06 §3 六态取值域）。 */
    public static final String CONTENT_STATUS_READY = "READY";

    /** 待回收态：引用恢复为 >0 时从这里回到就绪（06 §7）。 */
    public static final String CONTENT_STATUS_RECLAIM_PENDING = "RECLAIM_PENDING";

    private final ResourceMapper resourceMapper;
    private final ContentMapper contentMapper;

    public ProtectionReferenceService(ResourceMapper resourceMapper, ContentMapper contentMapper) {
        this.resourceMapper = resourceMapper;
        this.contentMapper = contentMapper;
    }

    /**
     * 保护引用实时计数（含回收站行）：按内容身份实查引用它的资源行数。
     * 索引已存在（{@code idx_resource_content_id}），此处不加任何过滤条件。
     */
    public long countProtecting(UUID contentId) {
        Long count = resourceMapper.selectCount(
                Wrappers.<ResourceEntity>lambdaQuery().eq(ResourceEntity::getContentId, contentId));
        return count == null ? 0L : count;
    }

    /**
     * 按当前保护引用数同步内容回收态（06 §7 的两条转换）：
     *
     * <ul>
     *   <li>引用数＝0 且内容 {@code READY} → {@code RECLAIM_PENDING}；</li>
     *   <li>引用数&gt;0 且内容 {@code RECLAIM_PENDING} → {@code READY}。</li>
     * </ul>
     *
     * <p>其余状态一律不动：{@code RECLAIMING}／{@code RECLAIMED} 属 GC 三段提交与复活路径的职责
     * （04 §5 ③、§7 末行），引用计数不越权把它们拉回就绪，否则会与「锁内复活须先校验字节」冲突。
     *
     * @return 本次同步的观测结果（计数、前后状态），便于调用方记录与断言
     */
    public SyncOutcome syncReclaimState(UUID contentId) {
        ContentEntity content = contentMapper.selectById(contentId);
        if (content == null) {
            throw CatalogException.internalError("内容 " + contentId + " 不存在，无法同步回收态");
        }
        long protecting = countProtecting(contentId);
        String before = content.getStatus();
        String after = nextStatus(before, protecting);
        if (!after.equals(before)) {
            ContentEntity patch = new ContentEntity();
            patch.setId(contentId);
            patch.setStatus(after);
            contentMapper.updateById(patch);
        }
        return new SyncOutcome(contentId, protecting, before, after);
    }

    /** 状态机（纯函数，便于单测逐格覆盖）：只实现 06 §7 中与保护引用有关的两条转换。 */
    static String nextStatus(String current, long protecting) {
        if (protecting == 0 && CONTENT_STATUS_READY.equals(current)) {
            return CONTENT_STATUS_RECLAIM_PENDING;
        }
        if (protecting > 0 && CONTENT_STATUS_RECLAIM_PENDING.equals(current)) {
            return CONTENT_STATUS_READY;
        }
        return current;
    }

    /** 同步结果：内容身份、观测到的保护引用数、状态前后值。 */
    public record SyncOutcome(UUID contentId, long protectingCount, String statusBefore, String statusAfter) {

        public boolean changed() {
            return !statusBefore.equals(statusAfter);
        }
    }
}
