package com.cangshu.api.dto;

import com.cangshu.search.ResourceQueryService;
import java.util.List;

/**
 * 资源列表信封（05-接口契约 §3.2）：{@code { "items": [Resource…], "total", "page", "size" }}。
 * 回收站列表（§3.6）共用同一信封形状，只是条目另带 {@code deletedAt}／{@code expireAt}（§1）。
 */
public record ResourceListResponse(List<ResourceResponse> items, long total, int page, int size) {

    public static ResourceListResponse from(ResourceQueryService.ResourcePage page) {
        return new ResourceListResponse(
                page.items().stream().map(ResourceResponse::listItem).toList(),
                page.total(),
                page.page(),
                page.size());
    }

    /** 回收站列表（契约 §3.6）：条目为「另带两个时间戳」的资源形状，其余与普通列表一致。 */
    public static ResourceListResponse fromTrash(ResourceQueryService.ResourcePage page) {
        return new ResourceListResponse(
                page.items().stream().map(ResourceResponse::trashItem).toList(),
                page.total(),
                page.page(),
                page.size());
    }
}
