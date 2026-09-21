package com.cangshu;

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
 */
@SpringBootApplication
@ConfigurationPropertiesScan
@EnableScheduling
@MapperScan({"com.cangshu.catalog.mapper", "com.cangshu.search.mapper"})
public class CangshuApplication {

    public static void main(String[] args) {
        SpringApplication.run(CangshuApplication.class, args);
    }
}
