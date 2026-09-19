package com.cangshu.api.dto;

import com.cangshu.search.ResourceQueryService;
import com.fasterxml.jackson.annotation.JsonInclude;
import java.time.OffsetDateTime;
import java.util.UUID;

/**
 * 资源对象（05-接口契约 §1）：列表项（§3.2）与详情（§3.3）共用。
 * 列表项 {@code contentId} 为 null（NON_NULL 不输出），JSON 即 §1 的 Resource 形状；
 * 详情输出 {@code contentId} 承载「Hash 与内容关联」的引用关系展示（REQ-M1-06；
 * 与上传响应 §3.1 的 {@code contentId} 同名字段同义）。回收站专用字段
 * {@code deletedAt}／{@code expireAt} 仅回收站列表携带（§1），本类不含。
 * {@code hash.algorithm} 对外为显示值 {@code sha256}（算法命名空间③，与上传响应一致）。
 */
@JsonInclude(JsonInclude.Include.NON_NULL)
public record ResourceResponse(
        UUID id,
        String name,
        Long sizeBytes,
        String mimeType,
        UploadResponse.HashView hash,
        java.util.List<String> tags,
        String status,
        OffsetDateTime createdAt,
        UUID contentId) {

    public static ResourceResponse listItem(ResourceQueryService.ResourceView view) {
        return of(view, null);
    }

    public static ResourceResponse detail(ResourceQueryService.ResourceView view) {
        return of(view, view.contentId());
    }

    private static ResourceResponse of(ResourceQueryService.ResourceView view, UUID contentId) {
        return new ResourceResponse(
                view.id(),
                view.name(),
                view.sizeBytes(),
                view.mimeType(),
                new UploadResponse.HashView("sha256", view.digest()),
                view.tags(),
                view.status(),
                view.createdAt(),
                contentId);
    }
}
