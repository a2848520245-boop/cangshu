package com.cangshu.api;

import com.cangshu.api.dto.EmptyTrashResponse;
import com.cangshu.api.dto.ResourceListResponse;
import com.cangshu.api.dto.ResourceResponse;
import com.cangshu.catalog.CatalogException;
import com.cangshu.catalog.TrashService;
import com.cangshu.search.ResourceQueryService;
import java.util.UUID;
import org.springframework.web.bind.annotation.DeleteMapping;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

/**
 * 回收站端点（api 模块：收发 HTTP、参数校验、错误码映射；M1 不鉴权）。任务 28（05-接口契约 §3.6–§3.8）：
 *
 * <ul>
 *   <li>{@code GET /api/resources/trash} → 200 分页信封，条目另带 {@code deletedAt}／{@code expireAt}；
 *       只返回已软删且尚未到期的资源。</li>
 *   <li>{@code POST /api/resources/{id}/restore} → 200 Resource，回到活跃列表；已硬删 → 404。</li>
 *   <li>{@code DELETE /api/resources/trash?confirm=true} → 200 {@code {deletedCount}}；
 *       缺失或为假 → 400 且不删除任何内容。</li>
 * </ul>
 *
 * <p>分页参数与 §3.2 同口径（上限 {@value ResourceController#MAX_PAGE_SIZE}，超出即 400）——
 * 2026-09-22 用户裁决定稿于 §3.6。列表读走 search 模块（api → search 是允许方向），
 * 还原与清空走 catalog（api → catalog）——两端点都经由分段锁保护的写入路径。
 */
@RestController
@RequestMapping("/api")
public class TrashController {

    private final ResourceQueryService queries;
    private final TrashService trash;

    public TrashController(ResourceQueryService queries, TrashService trash) {
        this.queries = queries;
        this.trash = trash;
    }

    /**
     * 回收站列表（契约 §3.6）：{@code page} 默认 1、{@code size} 默认 20、上限 200；
     * 参数非法或超出上限 → 400 {@code INVALID_ARGUMENT}（不得静默截断为上限值）。
     */
    @GetMapping("/resources/trash")
    public ResourceListResponse trash(
            @RequestParam(name = "page", defaultValue = "1") int page,
            @RequestParam(name = "size", defaultValue = "20") int size) {
        if (page < 1 || size < 1) {
            throw CatalogException.invalidArgument("分页参数非法：page 与 size 必须为不小于 1 的整数");
        }
        if (size > ResourceController.MAX_PAGE_SIZE) {
            throw CatalogException.invalidArgument(
                    "分页参数非法：size 不得超过 " + ResourceController.MAX_PAGE_SIZE + "（契约 §3.6）");
        }
        return ResourceListResponse.fromTrash(queries.trash(page, size));
    }

    /** 还原（契约 §3.7）：200 Resource；资源不存在或已硬删 → 404 {@code RESOURCE_NOT_FOUND}。 */
    @PostMapping("/resources/{id}/restore")
    public ResourceResponse restore(@PathVariable("id") UUID id) {
        trash.restore(id);
        // 还原成功后资源必然对普通详情可见（状态已回 READY）；取不到即异常，不静默返回伪造体。
        ResourceQueryService.ResourceView view = queries.detail(id)
                .orElseThrow(() -> CatalogException.internalError("还原后资源仍不可见，需排查"));
        return ResourceResponse.detail(view);
    }

    /**
     * 清空回收站（契约 §3.8）：只有显式 {@code confirm=true} 才执行；缺失、空值或任何其他取值都
     * 视为未确认 → 400 {@code INVALID_ARGUMENT} 且一行不删（08 §5 负例）。服务端不代填、无隐式路径。
     */
    @DeleteMapping("/resources/trash")
    public EmptyTrashResponse empty(
            @RequestParam(name = "confirm", required = false) String confirm) {
        boolean confirmed = confirm != null && "true".equalsIgnoreCase(confirm.trim());
        TrashService.EmptyTrashOutcome outcome = trash.emptyTrash(confirmed);
        return new EmptyTrashResponse(outcome.deletedCount());
    }
}
