package com.cangshu;

import org.mybatis.spring.annotation.MapperScan;
import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.boot.context.properties.ConfigurationPropertiesScan;

/**
 * 仓鼠 M1 应用入口。
 *
 * <p>任务 2 范围：最小可启动工程、健康检查与最小接口、六个定稿配置键的统一绑定层。
 * 任务 3 范围：单文件上传（api → ingest → storage/catalog）、内容寻址与复用／冲突判定、
 * PostgreSQL（MyBatis-Plus）数据访问。
 */
@SpringBootApplication
@ConfigurationPropertiesScan
@MapperScan({"com.cangshu.catalog.mapper", "com.cangshu.search.mapper"})
public class CangshuApplication {

    public static void main(String[] args) {
        SpringApplication.run(CangshuApplication.class, args);
    }
}
