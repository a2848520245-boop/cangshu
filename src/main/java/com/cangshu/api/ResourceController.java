package com.cangshu.api;

import com.cangshu.api.dto.UploadResponse;
import com.cangshu.catalog.CatalogException;
import com.cangshu.catalog.CatalogService;
import com.cangshu.ingest.StagedUpload;
import com.cangshu.ingest.UploadIngestService;
import java.io.IOException;
import java.io.InputStream;
import org.springframework.http.HttpStatus;
import org.springframework.http.MediaType;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.web.multipart.MultipartFile;

/**
 * 上传资源（任务 3；《05-M1-接口契约》§3.1）：{@code POST /api/resources}，
 * {@code multipart/form-data}，字段 {@code file}（必填、单文件）。
 * 服务端流式接收并同时计算 SHA-256，不整文件读入内存；相同内容复用已存在的物理内容。
 */
@RestController
@RequestMapping("/api")
public class ResourceController {

    private final UploadIngestService ingest;
    private final CatalogService catalog;

    public ResourceController(UploadIngestService ingest, CatalogService catalog) {
        this.ingest = ingest;
        this.catalog = catalog;
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
}
