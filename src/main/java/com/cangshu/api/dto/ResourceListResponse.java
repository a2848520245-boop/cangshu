package com.cangshu.api.dto;

import com.cangshu.search.ResourceQueryService;
import java.util.List;

/**
 * 资源列表信封（05-接口契约 §3.2）：{@code { "items": [Resource…], "total", "page", "size" }}。
 */
public record ResourceListResponse(List<ResourceResponse> items, long total, int page, int size) {

    public static ResourceListResponse from(ResourceQueryService.ResourcePage page) {
        return new ResourceListResponse(
                page.items().stream().map(ResourceResponse::listItem).toList(),
                page.total(),
                page.page(),
                page.size());
    }
}
