package com.cangshu.catalog;

import com.cangshu.catalog.entity.ContentEntity;
import com.cangshu.catalog.entity.LocationEntity;
import com.cangshu.catalog.entity.ResourceEntity;
import com.cangshu.catalog.mapper.ContentMapper;
import com.cangshu.catalog.mapper.LocationMapper;
import com.cangshu.catalog.mapper.ResourceMapper;
import com.cangshu.storage.FileStore;
import com.baomidou.mybatisplus.core.toolkit.Wrappers;
import java.io.IOException;
import java.io.InputStream;
import java.nio.file.NoSuchFileException;
import java.util.List;
import java.util.UUID;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Service;

/**
 * 下载解析（catalog 模块，任务 5；《05-M1-接口契约》§3.4／REQ-M1-07）。
 *
 * <p>api 不直接访问文件系统（04-架构与计划 §2 禁令 5）：本服务解析「资源 → 内容身份 → 位置」，
 * 校验通过后经 storage 打开只读流交 api 做 HTTP 编码。读路径不取分段锁（六类共锁只覆盖写路径），
 * 也不写任何表。下载字节与上传摘要一致的前提＝内容寻址键本身由摘要决定；「先比大小」在
 * 下载侧落为 {@code 盘上文件大小 = content.size_bytes} 的守卫。
 *
 * <p>失败语义（契约 §3.4＋08-验收规范 §4 故障矩阵）：
 * 资源不存在或已软删（回收站对普通下载不可见，与详情同口径）→ 404 {@code RESOURCE_NOT_FOUND}；
 * 内容行缺失／非就绪／位置异常／字节缺失／字节与身份大小不符 → 拒绝下载并告警（500），
 * <b>绝不返回空文件</b>。
 */
@Service
public class DownloadService {

    private static final Logger log = LoggerFactory.getLogger(DownloadService.class);

    static final String RESOURCE_STATUS_DELETED = "DELETED";
    static final String CONTENT_STATUS_READY = "READY";

    private final ResourceMapper resourceMapper;
    private final ContentMapper contentMapper;
    private final LocationMapper locationMapper;
    private final FileStore files;

    public DownloadService(ResourceMapper resourceMapper, ContentMapper contentMapper,
            LocationMapper locationMapper, FileStore files) {
        this.resourceMapper = resourceMapper;
        this.contentMapper = contentMapper;
        this.locationMapper = locationMapper;
        this.files = files;
    }

    /**
     * 下载载荷：响应头元数据 ＋ 已打开的内容字节流（api 层负责关闭与写出）。
     * {@code sizeBytes} 取自内容身份（已与盘上文件大小核对一致）。
     */
    public record DownloadPayload(UUID resourceId, UUID contentId, String name, String mimeType,
            long sizeBytes, InputStream stream) {
    }

    /** 解析并打开资源内容；校验不通过即抛 {@link CatalogException}，不产生半开的流。 */
    public DownloadPayload open(UUID resourceId) {
        ResourceEntity resource = resourceMapper.selectById(resourceId);
        if (resource == null || RESOURCE_STATUS_DELETED.equals(resource.getStatus())) {
            throw new CatalogException(CatalogException.Code.RESOURCE_NOT_FOUND, "资源不存在", null);
        }
        ContentEntity content = resource.getContentId() == null
                ? null
                : contentMapper.selectById(resource.getContentId());
        if (content == null || !CONTENT_STATUS_READY.equals(content.getStatus())) {
            log.error("CANGSHU|alert|resourceId={} 内容行缺失或非就绪状态，拒绝下载", resourceId);
            throw CatalogException.internalError("内容身份缺失或非就绪，拒绝下载并告警");
        }
        String storageKey = soleStorageKeyOf(content.getId());
        long blobSize;
        try {
            blobSize = files.blobSize(storageKey);
        } catch (NoSuchFileException e) {
            // 缺失字节属最高危（08 §4）：拒绝下载、触发对账（对账属任务 28）、必须告警。
            log.error("CANGSHU|alert|contentId={} 字节缺失（存储键 {}），拒绝下载", content.getId(), storageKey);
            throw CatalogException.internalError("内容字节缺失，拒绝下载并告警");
        } catch (IOException e) {
            log.error("CANGSHU|alert|contentId={} 读取字节大小失败，拒绝下载", content.getId(), e);
            throw CatalogException.internalError("内容字节读取失败，拒绝下载");
        }
        if (blobSize != content.getSizeBytes()) {
            log.error("CANGSHU|alert|contentId={} 字节大小与内容身份不符（盘上 {} / 身份 {}），拒绝下载",
                    content.getId(), blobSize, content.getSizeBytes());
            throw CatalogException.internalError("内容字节与身份不符，拒绝下载并告警");
        }
        InputStream stream;
        try {
            stream = files.open(storageKey);
        } catch (IOException e) {
            log.error("CANGSHU|alert|contentId={} 打开字节流失败，拒绝下载", content.getId(), e);
            throw CatalogException.internalError("内容字节打开失败，拒绝下载");
        }
        return new DownloadPayload(resourceId, content.getId(), resource.getName(),
                resource.getMimeType(), content.getSizeBytes(), stream);
    }

    /** 内容的位置记录必须恰有一条；异常数量属数据损坏，拒绝并告警（与上传侧 soleStorageKeyOf 同口径）。 */
    private String soleStorageKeyOf(UUID contentId) {
        List<LocationEntity> locations = locationMapper.selectList(
                Wrappers.<LocationEntity>lambdaQuery().eq(LocationEntity::getContentId, contentId));
        if (locations.size() != 1) {
            log.error("CANGSHU|alert|contentId={} 位置记录数异常：{}，拒绝下载", contentId, locations.size());
            throw CatalogException.internalError("内容 " + contentId + " 的位置记录数异常：" + locations.size());
        }
        return locations.get(0).getStorageKey();
    }
}
