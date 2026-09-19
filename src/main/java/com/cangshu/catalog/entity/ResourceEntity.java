package com.cangshu.catalog.entity;

import com.baomidou.mybatisplus.annotation.IdType;
import com.baomidou.mybatisplus.annotation.TableField;
import com.baomidou.mybatisplus.annotation.TableId;
import com.baomidou.mybatisplus.annotation.TableName;
import com.cangshu.common.jsonb.JsonbTypeHandler;
import com.cangshu.common.mybatis.CangshuUuidTypeHandler;
import java.time.OffsetDateTime;
import java.util.UUID;

/**
 * resource：逻辑资源条目（06-数据契约 §2）。软删等价约束由数据库 CHECK 承载；
 * content_id 普通索引、非唯一（多条资源可指向同一内容）。
 */
@TableName(value = "cangshu_m1.resource", autoResultMap = true)
public class ResourceEntity {

    /** ID 由应用侧生成（UUIDv7，IdType.INPUT）；UUID ↔ uuid 列映射走全局注册的 CangshuUuidTypeHandler。 */
    @TableId(value = "id", type = IdType.INPUT)
    private UUID id;

    @TableField("name")
    private String name;

    @TableField("size_bytes")
    private Long sizeBytes;

    @TableField("mime_type")
    private String mimeType;

    @TableField(value = "content_id", typeHandler = CangshuUuidTypeHandler.class)
    private UUID contentId;

    @TableField(value = "tags", typeHandler = JsonbTypeHandler.class)
    private String tags;

    @TableField("status")
    private String status;

    @TableField("deleted_at")
    private OffsetDateTime deletedAt;

    @TableField("expire_at")
    private OffsetDateTime expireAt;

    @TableField("created_at")
    private OffsetDateTime createdAt;

    @TableField("updated_at")
    private OffsetDateTime updatedAt;

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

    public UUID getContentId() {
        return contentId;
    }

    public void setContentId(UUID contentId) {
        this.contentId = contentId;
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

    public OffsetDateTime getDeletedAt() {
        return deletedAt;
    }

    public void setDeletedAt(OffsetDateTime deletedAt) {
        this.deletedAt = deletedAt;
    }

    public OffsetDateTime getExpireAt() {
        return expireAt;
    }

    public void setExpireAt(OffsetDateTime expireAt) {
        this.expireAt = expireAt;
    }

    public OffsetDateTime getCreatedAt() {
        return createdAt;
    }

    public void setCreatedAt(OffsetDateTime createdAt) {
        this.createdAt = createdAt;
    }

    public OffsetDateTime getUpdatedAt() {
        return updatedAt;
    }

    public void setUpdatedAt(OffsetDateTime updatedAt) {
        this.updatedAt = updatedAt;
    }
}
