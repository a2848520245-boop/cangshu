package com.cangshu.api.dto;

import com.cangshu.search.ResourceQueryService;
import com.fasterxml.jackson.annotation.JsonInclude;
import java.time.OffsetDateTime;
import java.util.UUID;

/**
 * 资源对象（05-接口契约 §1）：列表项（§3.2）、详情（§3.3）与回收站列表项（§3.6）共用。
 * 列表项 {@code contentId} 为 null（NON_NULL 不输出），JSON 即 §1 的 Resource 形状；
 * 详情输出 {@code contentId} 承载「Hash 与内容关联」的引用关系展示（REQ-M1-06；
 * 与上传响应 §3.1 的 {@code contentId} 同名字段同义）。回收站专用字段
 * {@code deletedAt}／{@code expireAt} 仅回收站列表携带（§1，非回收站项为 null 故不输出）。
 * {@code hash.algorithm} 对外为显示值 {@code sha256}（算法命名空间③，与上传响应一致）。
 */
@JsonInclude(JsonInclude.Include.NON_NULL)
public record ResourceResponse(
        UUID id,
        String name,
        Long sizeBytes,
        String mimeType,
        HashView hash,
        java.util.List<String> tags,
        String status,
        OffsetDateTime createdAt,
        UUID contentId,
        OffsetDateTime deletedAt,
        OffsetDateTime expireAt) {

    public static ResourceResponse listItem(ResourceQueryService.ResourceView view) {
        return of(view, null);
    }

    public static ResourceResponse detail(ResourceQueryService.ResourceView view) {
        return of(view, view.contentId());
    }

    /** 回收站列表项（契约 §3.6）：与列表项同形状，另带两个时间戳；不输出 contentId。 */
    public static ResourceResponse trashItem(ResourceQueryService.ResourceView view) {
        return of(view, null);
    }

    private static ResourceResponse of(ResourceQueryService.ResourceView view, UUID contentId) {
        return new ResourceResponse(
                view.id(),
                view.name(),
                view.sizeBytes(),
                view.mimeType(),
                HashView.sha256(view.digest()),
                view.tags(),
                view.status(),
                view.createdAt(),
                contentId,
                view.deletedAt(),
                view.expireAt());
    }
}
