package com.cangshu.search;

import com.cangshu.search.mapper.ResourceQueryMapper;
import com.cangshu.search.mapper.ResourceSummaryRow;
import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.core.type.TypeReference;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.time.OffsetDateTime;
import java.time.ZoneOffset;
import java.util.List;
import java.util.Optional;
import java.util.UUID;
import org.springframework.stereotype.Service;

/**
 * 资源列表／检索／详情查询（search 模块，任务 4；《05-M1-接口契约》§3.2／§3.3）。
 * 分页参数校验属 api 层职责（04-架构 §1）；本服务只执行查询与读模型组装。
 * 「未找到」以空 {@link Optional} 返回，由 api 层映射 404（search 不依赖 catalog 的异常类型）。
 */
@Service
public class ResourceQueryService {

    private static final ObjectMapper JSON = new ObjectMapper();
    private static final TypeReference<List<String>> TAG_LIST = new TypeReference<>() {
    };

    private final ResourceQueryMapper mapper;

    public ResourceQueryService(ResourceQueryMapper mapper) {
        this.mapper = mapper;
    }

    /** 资源读视图：resource 行 ＋ 内容身份（算法规范值与摘要）＋ contentId（引用关系展示）。 */
    public record ResourceView(UUID id, String name, long sizeBytes, String mimeType,
            List<String> tags, String status, OffsetDateTime createdAt, UUID contentId,
            String hashAlgorithm, String digest) {
    }

    /** 列表分页结果（契约 §3.2 信封形状由 api 层组装）。 */
    public record ResourcePage(List<ResourceView> items, long total, int page, int size) {
    }

    /**
     * 列表／检索（契约 §3.2）：{@code name} 文件名包含匹配、{@code tag} 标签过滤，两者同时给出按
     * AND 组合；空白视为未提供。{@code page}/{@code size} 由 api 层校验为正整数。
     */
    public ResourcePage list(String name, String tag, int page, int size) {
        String nameFilter = blankToNull(name);
        String tagFilter = blankToNull(tag);
        long offset = (long) (page - 1) * size;
        List<ResourceView> items = mapper.search(nameFilter, tagFilter, size, offset)
                .stream()
                .map(ResourceQueryService::toView)
                .toList();
        long total = mapper.countActive(nameFilter, tagFilter);
        return new ResourcePage(items, total, page, size);
    }

    /** 详情（契约 §3.3）：不存在或已在回收站 → 空 Optional。 */
    public Optional<ResourceView> detail(UUID id) {
        return Optional.ofNullable(mapper.findActiveById(id))
                .map(ResourceQueryService::toView);
    }

    private static ResourceView toView(ResourceSummaryRow row) {
        OffsetDateTime createdAt = row.getCreatedAt() == null
                ? null
                : row.getCreatedAt().withOffsetSameInstant(ZoneOffset.UTC);
        return new ResourceView(row.getId(), row.getName(), row.getSizeBytes(), row.getMimeType(),
                parseTags(row.getTags()), row.getStatus(), createdAt, row.getContentId(),
                row.getHashAlgorithm(), row.getDigest());
    }

    /** tags jsonb 文本 → 字符串数组（M1 简化结构）；畸形 JSON 属数据损坏，显式失败不静默。 */
    private static List<String> parseTags(String json) {
        if (json == null || json.isBlank()) {
            return List.of();
        }
        try {
            List<String> tags = JSON.readValue(json, TAG_LIST);
            return tags == null ? List.of() : List.copyOf(tags);
        } catch (JsonProcessingException e) {
            throw new IllegalStateException("标签 JSON 解析失败：" + json, e);
        }
    }

    private static String blankToNull(String value) {
        return value == null || value.isBlank() ? null : value;
    }
}
