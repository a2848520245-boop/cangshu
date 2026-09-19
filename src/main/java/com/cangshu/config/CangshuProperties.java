package com.cangshu.config;

import java.time.Duration;
import java.time.temporal.ChronoUnit;
import org.springframework.boot.context.properties.ConfigurationProperties;
import org.springframework.boot.convert.DurationUnit;
import org.springframework.util.unit.DataSize;

/**
 * 统一配置绑定层：[[07-M1-运行手册]] §1 的六个定稿键。
 *
 * <p>嵌套结构与定稿键逐段对齐，canonical 名必须精确等于手册键名：
 * {@code cangshu.data-root}、{@code cangshu.upload.max-size}、{@code cangshu.trash.retention}、
 * {@code cangshu.migration.dir}、{@code cangshu.migration.lock-key}、{@code cangshu.writer.lock-key}。
 * 环境变量映射（Boot 宽松绑定，{@code -} 与 {@code _} 互换）：{@code CANGSHU_DATA_ROOT}、
 * {@code CANGSHU_UPLOAD_MAX_SIZE}、{@code CANGSHU_TRASH_RETENTION}、{@code CANGSHU_MIGRATION_DIR}。
 * {@code cangshu.migration.lock-key} 与 {@code cangshu.writer.lock-key} 是协议常量，
 * 不支持普通环境变量或运行配置覆盖（锁键纪律）；默认值必须与运行手册登记值一致。
 */
@ConfigurationProperties(prefix = "cangshu")
public class CangshuProperties {

    /** {@code cangshu.migration.lock-key} 协议常量（登记值 20260918）。静态常量：不在绑定面上，环境变量与配置文件均无法覆盖。 */
    public static final long MIGRATION_LOCK_KEY = 20260918L;

    /** {@code cangshu.writer.lock-key} 协议常量（登记值 20260919）。静态常量：不在绑定面上，环境变量与配置文件均无法覆盖。 */
    public static final long WRITER_LOCK_KEY = 20260919L;

    /** 数据根目录；启动时解析并记录规范绝对路径，交付使用显式挂载路径。 */
    private String dataRoot = "./var/data-root";

    private final Upload upload = new Upload();

    private final Trash trash = new Trash();

    private final Migration migration = new Migration();

    /** {@code cangshu.upload.*}：单文件业务上限（业务值）；HTTP 层 multipart 限制在任务 3（上传）落地时与此同源。 */
    public static class Upload {

        private DataSize maxSize = DataSize.ofGigabytes(2);

        public DataSize getMaxSize() {
            return maxSize;
        }

        public void setMaxSize(DataSize maxSize) {
            this.maxSize = maxSize;
        }
    }

    /** {@code cangshu.trash.*}：回收站保留期；允许测试值 0，禁止负数。 */
    public static class Trash {

        @DurationUnit(ChronoUnit.DAYS)
        private Duration retention = Duration.ofDays(7);

        public Duration getRetention() {
            return retention;
        }

        public void setRetention(Duration retention) {
            this.retention = retention;
        }
    }

    /** {@code cangshu.migration.*}：迁移脚本目录。 */
    public static class Migration {

        /** 迁移脚本目录；启动确认可读及脚本集合（属任务 12／30，本任务仅绑定配置）。 */
        private String dir = "./db/migration";

        public String getDir() {
            return dir;
        }

        public void setDir(String dir) {
            this.dir = dir;
        }
    }

    public String getDataRoot() {
        return dataRoot;
    }

    public void setDataRoot(String dataRoot) {
        this.dataRoot = dataRoot;
    }

    public Upload getUpload() {
        return upload;
    }

    public Trash getTrash() {
        return trash;
    }

    public Migration getMigration() {
        return migration;
    }
}
