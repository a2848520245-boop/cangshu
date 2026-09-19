package com.cangshu.api;

import com.cangshu.config.CangshuProperties;
import com.cangshu.config.StartupConfigLogger;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

/**
 * 最小接口与配置回显（任务 2）。
 *
 * <p>《05-M1-接口契约》总则约定 Base URL {@code /api}、REST＋JSON、JSON 字段 {@code camelCase}；
 * 契约八端点属任务 3～6，本控制器只提供任务 2 的最小可调用接口 {@code GET /api/health}，
 * 回显六个定稿配置键的生效值（含数据根规范绝对路径），用于 DOC-BOOT「配置与数据根说明可复现」。
 */
@RestController
@RequestMapping("/api")
public class HealthController {

    private final CangshuProperties properties;

    public HealthController(CangshuProperties properties) {
        this.properties = properties;
    }

    @GetMapping("/health")
    public ServiceHealth health() {
        return new ServiceHealth(
                "UP",
                "cangshu",
                new ConfigSnapshot(
                        StartupConfigLogger.resolveAbsolute(properties.getDataRoot()),
                        properties.getUpload().getMaxSize().toBytes(),
                        properties.getTrash().getRetention().toString(),
                        StartupConfigLogger.resolveAbsolute(properties.getMigration().getDir()),
                        CangshuProperties.MIGRATION_LOCK_KEY,
                        CangshuProperties.WRITER_LOCK_KEY));
    }

    /** 响应体：{@code /api/health} 的定稿形状（任务 2 最小接口）。 */
    public record ServiceHealth(String status, String service, ConfigSnapshot config) {
    }

    /** 六个定稿配置键的生效值；路径为解析后的规范绝对路径。 */
    public record ConfigSnapshot(String dataRoot, long uploadMaxSizeBytes, String trashRetention,
            String migrationDir, long migrationLockKey, long writerLockKey) {
    }
}
