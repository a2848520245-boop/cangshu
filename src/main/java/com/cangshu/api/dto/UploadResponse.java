package com.cangshu.api.dto;

import com.cangshu.catalog.CatalogService;
import com.fasterxml.jackson.annotation.JsonInclude;
import java.time.OffsetDateTime;
import java.time.ZoneOffset;
import java.util.List;
import java.util.UUID;

/**
 * 上传响应（05-接口契约 §3.1）：资源形状 ＋ {@code deduplicated} ＋ {@code contentId}。
 * {@code hash.algorithm} 对外为显示值 {@code sha256}（算法命名空间③）；时间为 ISO-8601 UTC。
 */
@JsonInclude(JsonInclude.Include.NON_NULL)
public record UploadResponse(
        UUID id,
        String name,
        Long sizeBytes,
        String mimeType,
        HashView hash,
        List<String> tags,
        String status,
        OffsetDateTime createdAt,
        Boolean deduplicated,
        UUID contentId) {

    /** {@code hash} 对象：显示值算法 ＋ 小写 64 位十六进制摘要。 */
    public record HashView(String algorithm, String digest) {
    }

    public static UploadResponse from(CatalogService.UploadResult result) {
        return new UploadResponse(
                result.resourceId(),
                result.name(),
                result.sizeBytes(),
                result.mimeType(),
                new HashView("sha256", result.digest()),
                List.of(),
                "READY",
                result.createdAt().withOffsetSameInstant(ZoneOffset.UTC),
                result.deduplicated(),
                result.contentId());
    }
}
