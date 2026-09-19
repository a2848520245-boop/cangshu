package com.cangshu.ingest;

import com.cangshu.catalog.CatalogException;
import com.cangshu.config.CangshuProperties;
import com.cangshu.storage.Digestor;
import com.cangshu.storage.FileStore;
import com.cangshu.storage.StorageLimitExceededException;
import java.io.IOException;
import java.io.InputStream;
import org.springframework.stereotype.Service;

/**
 * 接收上传（ingest 模块，04-架构与计划 §1）：流式落临时文件、算摘要；不写最终内容键、
 * 不碰数据库表、不做锁与冲突判定。业务上限取 {@code cangshu.upload.max-size}（与 HTTP 层同源）。
 */
@Service
public class UploadIngestService {

    private final FileStore files;
    private final Digestor digestor;
    private final CangshuProperties properties;

    public UploadIngestService(FileStore files, Digestor digestor, CangshuProperties properties) {
        this.files = files;
        this.digestor = digestor;
        this.properties = properties;
    }

    /**
     * 流式接收并计算摘要；声明大小与实际接收不符视为内容损坏（HASH_MISMATCH，422）。
     *
     * @param declaredSizeBytes multipart 声明的字节数；{@code null} 或负数表示未知
     */
    public StagedUpload stage(InputStream in, Long declaredSizeBytes) {
        long maxBytes = properties.getUpload().getMaxSize().toBytes();
        FileStore.Staged staged;
        try {
            staged = files.stage(in, maxBytes, digestor);
        } catch (StorageLimitExceededException e) {
            throw CatalogException.payloadTooLarge(
                    "单文件超过上限 " + e.maxBytes() + " 字节（已接收 " + e.receivedBytes() + " 字节）");
        } catch (IOException e) {
            throw CatalogException.internalError("接收上传流失败：" + e.getMessage());
        }
        if (declaredSizeBytes != null && declaredSizeBytes >= 0 && declaredSizeBytes != staged.sizeBytes()) {
            files.deleteTemp(staged.temp());
            throw CatalogException.hashMismatch("声明大小 " + declaredSizeBytes + " 与实际接收 "
                    + staged.sizeBytes() + " 字节不一致（内容损坏），未入库");
        }
        return new StagedUpload(staged.temp(), staged.canonicalAlgorithm(), staged.digest(), staged.sizeBytes());
    }
}
