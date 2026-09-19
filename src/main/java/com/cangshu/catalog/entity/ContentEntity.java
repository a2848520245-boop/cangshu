package com.cangshu.catalog.entity;

import com.baomidou.mybatisplus.annotation.IdType;
import com.baomidou.mybatisplus.annotation.TableField;
import com.baomidou.mybatisplus.annotation.TableId;
import com.baomidou.mybatisplus.annotation.TableName;
import java.time.OffsetDateTime;
import java.util.UUID;

/**
 * content：内容身份（算法＋摘要＋大小三元组），不含任何二进制列（06-数据契约 §3）。
 * 规范值 {@code SHA-256}；摘要小写 64 位十六进制。
 */
@TableName(value = "cangshu_m1.content", autoResultMap = true)
public class ContentEntity {

    /** ID 由应用侧生成（UUIDv7，IdType.INPUT）；UUID ↔ uuid 列映射走全局注册的 CangshuUuidTypeHandler。 */
    @TableId(value = "id", type = IdType.INPUT)
    private UUID id;

    @TableField("hash_algorithm")
    private String hashAlgorithm;

    @TableField("digest")
    private String digest;

    @TableField("size_bytes")
    private Long sizeBytes;

    @TableField("status")
    private String status;

    @TableField("created_at")
    private OffsetDateTime createdAt;

    public UUID getId() {
        return id;
    }

    public void setId(UUID id) {
        this.id = id;
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

    public Long getSizeBytes() {
        return sizeBytes;
    }

    public void setSizeBytes(Long sizeBytes) {
        this.sizeBytes = sizeBytes;
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
}
