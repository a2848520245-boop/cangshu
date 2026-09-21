package com.cangshu.catalog.mapper;

import java.util.UUID;

/**
 * 回收站行投影（catalog 内部）：硬删要「删行 ＋ 按内容身份取分段锁 ＋ 引用归零判定」，
 * 因此一次查出资源 id、内容 id 与内容身份（算法＋摘要）三样，避免逐行回查内容表。
 */
public class TrashRow {

    private UUID resourceId;
    private UUID contentId;
    private String hashAlgorithm;
    private String digest;

    public UUID getResourceId() {
        return resourceId;
    }

    public void setResourceId(UUID resourceId) {
        this.resourceId = resourceId;
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
