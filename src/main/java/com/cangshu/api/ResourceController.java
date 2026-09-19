package com.cangshu.api;

import com.cangshu.api.dto.ResourceListResponse;
import com.cangshu.api.dto.ResourceResponse;
import com.cangshu.api.dto.UploadResponse;
import com.cangshu.catalog.CatalogException;
import com.cangshu.catalog.CatalogService;
import com.cangshu.ingest.StagedUpload;
import com.cangshu.ingest.UploadIngestService;
import com.cangshu.search.ResourceQueryService;
import java.io.IOException;
import java.io.InputStream;
import java.util.UUID;
import org.springframework.http.HttpStatus;
import org.springframework.http.MediaType;
import org.springframework.http.ResponseEntity;
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
 * </ul>
 */
@RestController
@RequestMapping("/api")
public class ResourceController {

    private final UploadIngestService ingest;
    private final CatalogService catalog;
    private final ResourceQueryService queries;

    public ResourceController(UploadIngestService ingest, CatalogService catalog,
            ResourceQueryService queries) {
        this.ingest = ingest;
        this.catalog = catalog;
        this.queries = queries;
    }

    @PostMapping(value = "/resources", consumes = MediaType.MULTIPART_FORM_DATA_VALUE)
    public ResponseEntity<UploadResponse> upload(@RequestParam("file") MultipartFile file) throws IOException {
        if (file == null) {
            throw CatalogException.invalidArgument("缺少必填的 multipart 字段 file");
        }
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
}
