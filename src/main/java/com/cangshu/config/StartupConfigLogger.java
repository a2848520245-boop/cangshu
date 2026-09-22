package com.cangshu.config;

import java.nio.file.Path;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.boot.context.event.ApplicationReadyEvent;
import org.springframework.context.event.EventListener;
import org.springframework.stereotype.Component;

/**
 * 启动时解析并记录配置的规范绝对路径（[[07-M1-运行手册]] §1：数据根「启动解析并记录规范绝对路径」）。
 * 输出一行结构化日志 {@code CANGSHU|config|...}，供启动证据与配置复现核对。
 */
@Component
public class StartupConfigLogger {

    private static final Logger log = LoggerFactory.getLogger(StartupConfigLogger.class);

    private final CangshuProperties properties;

    public StartupConfigLogger(CangshuProperties properties) {
        this.properties = properties;
    }

    @EventListener(ApplicationReadyEvent.class)
    public void logResolvedConfig() {
        log.info("CANGSHU|config|dataRoot={}|uploadMaxSizeBytes={}|trashRetention={}|migrationDir={}|migrationLockKey={}|writerLockKey={}|writerLockFile={}",
                resolveAbsolute(properties.getDataRoot()),
                properties.getUpload().getMaxSize().toBytes(),
                properties.getTrash().getRetention(),
                resolveAbsolute(properties.getMigration().getDir()),
                CangshuProperties.MIGRATION_LOCK_KEY,
                CangshuProperties.WRITER_LOCK_KEY,
                writerLockFile());
    }

    /** 单写者门的数据根文件锁路径（任务 29）：数据根下的 {@code .cangshu-writer.lock}，属协议标记不计业务字节。 */
    private Path writerLockFile() {
        return Path.of(resolveAbsolute(properties.getDataRoot()), WriterGate.LOCK_FILE_NAME);
    }

    /** 把原始路径解析为规范绝对路径；数据根与迁移目录的统一取值口径（07-运行手册 §1）。 */
    public static String resolveAbsolute(String rawPath) {
        return Path.of(rawPath).toAbsolutePath().normalize().toString();
    }
}
