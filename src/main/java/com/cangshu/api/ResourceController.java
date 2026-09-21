package com.cangshu.api;

import com.cangshu.api.dto.ResourceListResponse;
import com.cangshu.api.dto.ResourceResponse;
import com.cangshu.api.dto.UploadResponse;
import com.cangshu.catalog.CatalogException;
import com.cangshu.catalog.CatalogService;
import com.cangshu.catalog.DownloadService;
import com.cangshu.catalog.TrashService;
import com.cangshu.ingest.StagedUpload;
import com.cangshu.ingest.UploadIngestService;
import com.cangshu.search.ResourceQueryService;
import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.util.UUID;
import org.springframework.http.InvalidMediaTypeException;
import org.springframework.core.io.InputStreamResource;
import org.springframework.http.ContentDisposition;
import org.springframework.http.HttpHeaders;
import org.springframework.http.HttpStatus;
import org.springframework.http.MediaType;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.DeleteMapping;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.web.multipart.MultipartFile;

/**
 * 资源端点（api 模块：收发 HTTP、参数校验、错误码映射；M1 不鉴权）。
 *
 * <ul>
 *   <li>任务 3（05-接口契约 §3.1）：{@code POST /api/resources} 上传，流式接收＋计算 SHA-256。</li>
 *   <li>任务 4（05-接口契约 §3.2／§3.3）：{@code GET /api/resources} 列表与文件名／标签检索、
 *       {@code GET /api/resources/{id}} 详情（{@code contentId} 引用关系展示）；
 *       回收站中的资源对普通列表／详情不可见（REQ-M1-04／06）。</li>
 *   <li>任务 5（05-接口契约 §3.4）：{@code GET /api/resources/{id}/content} 下载与
 *       {@code inline=1} 预览（REQ-M1-07，不自研格式解析器）。</li>
 *   <li>任务 6（05-接口契约 §3.5）：{@code DELETE /api/resources/{id}} 软删 → 204，
 *       资源进回收站（置 {@code deletedAt}／{@code expireAt}），字节与引用不动。</li>
 * </ul>
 */
@RestController
@RequestMapping("/api")
public class ResourceController {

    /** 单页条数上限（契约 §3.2，2026-09-20 澄清 `CL-PAGESIZE` 裁决）：超出即 400，不静默截断。 */
    public static final int MAX_PAGE_SIZE = 200;

    private final UploadIngestService ingest;
    private final CatalogService catalog;
    private final ResourceQueryService queries;
    private final DownloadService downloads;
    private final TrashService trash;

    public ResourceController(UploadIngestService ingest, CatalogService catalog,
            ResourceQueryService queries, DownloadService downloads, TrashService trash) {
        this.ingest = ingest;
        this.catalog = catalog;
        this.queries = queries;
        this.downloads = downloads;
        this.trash = trash;
    }

    @PostMapping(value = "/resources", consumes = MediaType.MULTIPART_FORM_DATA_VALUE)
    public ResponseEntity<UploadResponse> upload(@RequestParam("file") MultipartFile file) throws IOException {
        // 字段缺失由 Spring 抛 MissingServletRequestPartException，经 ApiExceptionHandler 映射为 400；
        // 这里只校验字段存在之后的取值（原始文件名）。
        String name = file.getOriginalFilename();
        if (name == null || name.isBlank()) {
            throw CatalogException.invalidArgument("上传文件缺少原始文件名");
        }
        String mimeType = file.getContentType();
        if (mimeType == null || mimeType.isBlank()) {
            mimeType = "application/octet-stream";
        }
        StagedUpload staged;
        try (InputStream in = file.getInputStream()) {
            staged = ingest.stage(in, file.getSize());
        }
        CatalogService.UploadResult result = catalog.upload(staged, name, mimeType);
        return ResponseEntity.status(HttpStatus.CREATED).body(UploadResponse.from(result));
    }

    /**
     * 列表／检索（契约 §3.2）：{@code name} 文件名包含匹配（大小写不敏感）、{@code tag} 标签过滤、
     * {@code page}（默认 1）与 {@code size}（默认 20）分页；参数非法 → 400 {@code INVALID_ARGUMENT}。
     * 排序固定 id DESC（UUIDv7 时间有序，实现口径见 ResourceQueryMapper）。
     *
     * <p>{@code size} 上限 {@value #MAX_PAGE_SIZE}（契约 §3.2，2026-09-20 澄清后补入）：无上界时
     * 单次请求可把全表读进内存，与 ACC-G1 的百万级元数据目标冲突。
     */
    @GetMapping("/resources")
    public ResourceListResponse list(
            @RequestParam(name = "name", required = false) String name,
            @RequestParam(name = "tag", required = false) String tag,
            @RequestParam(name = "page", defaultValue = "1") int page,
            @RequestParam(name = "size", defaultValue = "20") int size) {
        if (page < 1 || size < 1) {
            throw CatalogException.invalidArgument("分页参数非法：page 与 size 必须为不小于 1 的整数");
        }
        if (size > MAX_PAGE_SIZE) {
            throw CatalogException.invalidArgument(
                    "分页参数非法：size 不得超过 " + MAX_PAGE_SIZE + "（契约 §3.2）");
        }
        return ResourceListResponse.from(queries.list(name, tag, page, size));
    }

    /** 详情（契约 §3.3）：不存在或已在回收站 → 404 {@code RESOURCE_NOT_FOUND}。 */
    @GetMapping("/resources/{id}")
    public ResourceResponse detail(@PathVariable("id") UUID id) {
        ResourceQueryService.ResourceView view = queries.detail(id)
                .orElseThrow(() -> new CatalogException(
                        CatalogException.Code.RESOURCE_NOT_FOUND, "资源不存在", null));
        return ResourceResponse.detail(view);
    }

    /**
     * 软删（契约 §3.5，任务 6）：置删除态并写软删时刻与固定到期时刻，资源进入回收站 → 204（无响应体）。
     *
     * <p>语义：**只删引用**——内容行与物理字节不动，保护引用计数照样包含这一行，因此软删不触发
     * 内容待回收；到期或显式清空才硬删（清空属任务 28）。软删**幂等**：重复调用返回 204 且不刷新
     * 首次到期时刻（06 §8）。硬删后资源行已不存在 → 404 {@code RESOURCE_NOT_FOUND}（契约 §3.5）。
     */
    @DeleteMapping("/resources/{id}")
    public ResponseEntity<Void> delete(@PathVariable("id") UUID id) {
        trash.softDelete(id);
        return ResponseEntity.noContent().build();
    }

    /**
     * 下载／预览（契约 §3.4，任务 5）：默认 {@code attachment; filename*=UTF-8''…}；
     * {@code inline=1} 只把处置形态改为 {@code inline}（图片／PDF／文本／音视频由浏览器原生
     * 预览，服务端不自研格式解析器——REQ-M1-07），字节来源与摘要不变。{@code inline} 仅接受
     * {@code 1}，其他取值 → 400 {@code INVALID_ARGUMENT}。资源不存在／已在回收站 → 404；
     * 字节缺失或与内容身份不符 → 拒绝下载（500 并告警），绝不返回空文件（08-验收规范 §4）。
     * Content-Length 取自内容身份（下载服务已核对盘上大小一致），流式写出，内存不随文件大小增长。
     */
    @GetMapping("/resources/{id}/content")
    public ResponseEntity<InputStreamResource> content(@PathVariable("id") UUID id,
            @RequestParam(name = "inline", required = false) String inline) {
        if (inline != null && !"1".equals(inline)) {
            throw CatalogException.invalidArgument("inline 参数仅接受 1（下载不带该参数）");
        }
        DownloadService.DownloadPayload payload = downloads.open(id);
        ContentDisposition disposition = ("1".equals(inline)
                        ? ContentDisposition.inline()
                        : ContentDisposition.attachment())
                .filename(payload.name(), StandardCharsets.UTF_8)
                .build();
        return ResponseEntity.ok()
                .header(HttpHeaders.CONTENT_DISPOSITION, disposition.toString())
                .contentType(safeMediaType(payload.mimeType()))
                .contentLength(payload.sizeBytes())
                .body(new InputStreamResource(payload.stream()));
    }

    /** MIME 类型为上传时声明值；畸形值（不可解析）退回 application/octet-stream，不猜格式。 */
    private static MediaType safeMediaType(String mimeType) {
        if (mimeType == null || mimeType.isBlank()) {
            return MediaType.APPLICATION_OCTET_STREAM;
        }
        try {
            return MediaType.parseMediaType(mimeType);
        } catch (InvalidMediaTypeException e) {
            return MediaType.APPLICATION_OCTET_STREAM;
        }
    }
}
