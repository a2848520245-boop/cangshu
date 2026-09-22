package com.cangshu;

import com.cangshu.migration.MigrationVerificationException;
import com.cangshu.migration.SchemaVerifier;
import com.cangshu.config.WriterGate;
import org.mybatis.spring.annotation.MapperScan;
import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.boot.context.properties.ConfigurationPropertiesScan;
import org.springframework.scheduling.annotation.EnableScheduling;

/**
 * 仓鼠 M1 应用入口。
 *
 * <p>任务 2 范围：最小可启动工程、健康检查与最小接口、六个定稿配置键的统一绑定层。
 * 任务 3 范围：单文件上传（api → ingest → storage/catalog）、内容寻址与复用／冲突判定、
 * PostgreSQL（MyBatis-Plus）数据访问。
 * 任务 28 范围：回收站三端点（api）与后台作业（job：到期清空、GC 三段提交、每日对账三类）——
 * 因此在此开启调度（07-运行手册 §6 的每小时 GC／每日对账）；启动那一次对账由
 * `MaintenanceScheduler` 的 {@code SmartInitializingSingleton} 回调在 HTTP 容器开始服务之前完成。
 * 任务 29 范围：单写者启动门（{@link WriterGate}）先取 DB 会话锁与数据根文件锁，失锁即停写；
 * 启动门的失败与迁移核对失败各自映射到运行手册登记的两个退出码，互不混淆。
 */
@SpringBootApplication
@ConfigurationPropertiesScan
@EnableScheduling
@MapperScan({"com.cangshu.catalog.mapper", "com.cangshu.search.mapper"})
public class CangshuApplication {

    public static void main(String[] args) {
        try {
            SpringApplication.run(CangshuApplication.class, args);
        } catch (RuntimeException exception) {
            if (hasWriterGateDenial(exception)) {
                System.exit(WriterGate.EXIT_CODE);
                return;
            }
            if (hasMigrationVerificationFailure(exception)) {
                System.exit(SchemaVerifier.EXIT_CODE);
                return;
            }
            throw exception;
        }
    }

    /** 单写者门失败（未拿到 DB 会话锁或数据根文件锁）→ 退出码 2（07 §7；04 §8 步骤 1）。 */
    static boolean hasWriterGateDenial(Throwable throwable) {
        for (Throwable current = throwable; current != null; current = current.getCause()) {
            if (current instanceof WriterGate.WriterGateDeniedException) {
                return true;
            }
        }
        return false;
    }

    static boolean hasMigrationVerificationFailure(Throwable throwable) {
        for (Throwable current = throwable; current != null; current = current.getCause()) {
            if (current instanceof MigrationVerificationException) {
                return true;
            }
        }
        return false;
    }
}
