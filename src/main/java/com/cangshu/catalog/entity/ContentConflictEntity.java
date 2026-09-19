package com.cangshu.catalog.entity;

import com.baomidou.mybatisplus.annotation.IdType;
import com.baomidou.mybatisplus.annotation.TableField;
import com.baomidou.mybatisplus.annotation.TableId;
import com.baomidou.mybatisplus.annotation.TableName;
import com.cangshu.common.mybatis.CangshuUuidTypeHandler;
import java.time.OffsetDateTime;
import java.util.UUID;

/**
 * content_conflict：冲突审计（06-数据契约 §4）。可空字段仅限既有侧三项；
 * {@code incoming_size_bytes}／{@code incoming_storage_key} 必有（DEC-I5）。
 * 写入走独立短事务：业务事务回滚后审计仍保留。
 */
@TableName(value = "cangshu_m1.content_conflict", autoResultMap = true)
public class ContentConflictEntity {

    /** ID 由应用侧生成（UUIDv7，IdType.INPUT）；UUID ↔ uuid 列映射走全局注册的 CangshuUuidTypeHandler。 */
    @TableId(value = "id", type = IdType.INPUT)
    private UUID id;

    @TableField("hash_algorithm")
    private String hashAlgorithm;

    @TableField("digest")
    private String digest;

    @TableField(value = "existing_content_id", typeHandler = CangshuUuidTypeHandler.class)
    private UUID existingContentId;

    @TableField("existing_size_bytes")
    private Long existingSizeBytes;

    @TableField("incoming_size_bytes")
    private Long incomingSizeBytes;

    @TableField("existing_storage_key")
    private String existingStorageKey;

    @TableField("incoming_storage_key")
    private String incomingStorageKey;

    @TableField("reason")
    private String reason;

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

    public UUID getExistingContentId() {
        return existingContentId;
    }

    public void setExistingContentId(UUID existingContentId) {
        this.existingContentId = existingContentId;
    }

    public Long getExistingSizeBytes() {
        return existingSizeBytes;
    }

    public void setExistingSizeBytes(Long existingSizeBytes) {
        this.existingSizeBytes = existingSizeBytes;
    }

    public Long getIncomingSizeBytes() {
        return incomingSizeBytes;
    }

    public void setIncomingSizeBytes(Long incomingSizeBytes) {
        this.incomingSizeBytes = incomingSizeBytes;
    }

    public String getExistingStorageKey() {
        return existingStorageKey;
    }

    public void setExistingStorageKey(String existingStorageKey) {
        this.existingStorageKey = existingStorageKey;
    }

    public String getIncomingStorageKey() {
        return incomingStorageKey;
    }

    public void setIncomingStorageKey(String incomingStorageKey) {
        this.incomingStorageKey = incomingStorageKey;
    }

    public String getReason() {
        return reason;
    }

    public void setReason(String reason) {
        this.reason = reason;
    }

    public OffsetDateTime getCreatedAt() {
        return createdAt;
    }

    public void setCreatedAt(OffsetDateTime createdAt) {
        this.createdAt = createdAt;
    }
}
