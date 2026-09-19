package com.cangshu;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.boot.context.properties.ConfigurationPropertiesScan;

/**
 * 仓鼠 M1 应用入口。
 *
 * <p>任务 2 范围：最小可启动工程、健康检查与最小接口、六个定稿配置键的统一绑定层。
 * 数据源与 ORM 属任务 12（对象化数据模型），本工程暂不引入任何数据源。
 */
@SpringBootApplication
@ConfigurationPropertiesScan
public class CangshuApplication {

    public static void main(String[] args) {
        SpringApplication.run(CangshuApplication.class, args);
    }
}
