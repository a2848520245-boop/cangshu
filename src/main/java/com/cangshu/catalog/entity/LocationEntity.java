package com.cangshu.catalog.entity;

import com.baomidou.mybatisplus.annotation.IdType;
import com.baomidou.mybatisplus.annotation.TableField;
import com.baomidou.mybatisplus.annotation.TableId;
import com.baomidou.mybatisplus.annotation.TableName;
import com.cangshu.common.mybatis.CangshuUuidTypeHandler;
import java.util.UUID;

/**
 * location：位置（存储后端＋相对存储键）（06-数据契约 §5）。
 * storage_backend 固定 {@code filesystem}；storage_key＝{@code sha256/ab/cd/<digest>} 相对键。
 */
@TableName(value = "cangshu_m1.location", autoResultMap = true)
public class LocationEntity {

    /** ID 由应用侧生成（UUIDv7，IdType.INPUT）；UUID ↔ uuid 列映射走全局注册的 CangshuUuidTypeHandler。 */
    @TableId(value = "id", type = IdType.INPUT)
    private UUID id;

    @TableField(value = "content_id", typeHandler = CangshuUuidTypeHandler.class)
    private UUID contentId;

    @TableField("storage_backend")
    private String storageBackend;

    @TableField("storage_key")
    private String storageKey;

    public UUID getId() {
        return id;
    }

    public void setId(UUID id) {
        this.id = id;
    }

    public UUID getContentId() {
        return contentId;
    }

    public void setContentId(UUID contentId) {
        this.contentId = contentId;
    }

    public String getStorageBackend() {
        return storageBackend;
    }

    public void setStorageBackend(String storageBackend) {
        this.storageBackend = storageBackend;
    }

    public String getStorageKey() {
        return storageKey;
    }

    public void setStorageKey(String storageKey) {
        this.storageKey = storageKey;
    }
}
