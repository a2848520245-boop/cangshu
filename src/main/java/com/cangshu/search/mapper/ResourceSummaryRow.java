package com.cangshu.search.mapper;

import java.time.OffsetDateTime;
import java.util.UUID;

/**
 * 资源查询行（search 模块内部读模型）：resource 与 content 的只读投影，
 * 列名经 {@code map-underscore-to-camel-case} 自动映射；tags 以 jsonb 文本承载，由服务层解析。
 */
public class ResourceSummaryRow {

    private UUID id;
    private String name;
    private Long sizeBytes;
    private String mimeType;
    private String tags;
    private String status;
    private OffsetDateTime createdAt;
    private UUID contentId;
    private String hashAlgorithm;
    private String digest;

    public UUID getId() {
        return id;
    }

    public void setId(UUID id) {
        this.id = id;
    }

    public String getName() {
        return name;
    }

    public void setName(String name) {
        this.name = name;
    }

    public Long getSizeBytes() {
        return sizeBytes;
    }

    public void setSizeBytes(Long sizeBytes) {
        this.sizeBytes = sizeBytes;
    }

    public String getMimeType() {
        return mimeType;
    }

    public void setMimeType(String mimeType) {
        this.mimeType = mimeType;
    }

    public String getTags() {
        return tags;
    }

    public void setTags(String tags) {
        this.tags = tags;
    }

    public String getStatus() {
        return status;
    }

    public void setStatus(String status) {
        this.status = status;
    }

    public OffsetDateTime getCreatedAt() {
        return createdAt;
    }

    public void setCreatedAt(OffsetDateTime createdAt) {
        this.createdAt = createdAt;
    }

    public UUID getContentId() {
        return contentId;
    }

    public void setContentId(UUID contentId) {
        this.contentId = contentId;
    }

    public String getHashAlgorithm() {
        return hashAlgorithm;
    }

    public void setHashAlgorithm(String hashAlgorithm) {
        this.hashAlgorithm = hashAlgorithm;
    }

    public String getDigest() {
        return digest;
    }

    public void setDigest(String digest) {
        this.digest = digest;
    }
}
