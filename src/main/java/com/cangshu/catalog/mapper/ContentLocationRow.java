package com.cangshu.catalog.mapper;

import java.util.UUID;

/**
 * 对账用的「内容 ＋ 位置」只读投影（catalog 内部）：缺失字节判定要同时看内容身份（摘要与大小）
 * 与位置键，一次分页查询取齐，避免逐行回查。
 */
public class ContentLocationRow {

    private UUID contentId;
    private String hashAlgorithm;
    private String digest;
    private Long sizeBytes;
    private String status;
    private String storageKey;

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

    public String getStorageKey() {
        return storageKey;
    }

    public void setStorageKey(String storageKey) {
        this.storageKey = storageKey;
    }
}
