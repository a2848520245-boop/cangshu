package com.cangshu.config;

import com.cangshu.storage.FileStore;
import java.nio.file.Path;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

/**
 * 存储装配（P0-3④ D）：在装配层把数据根解析**一次**，再把纯路径交给 {@link FileStore}。
 *
 * <p>为什么要有这个类：04-架构与计划 §1 的方向图不允许 {@code storage → config}。D 之前
 * {@code FileStore} 的构造器直接吃 {@code CangshuProperties}，storage 于是反向读取业务配置；
 * 现在解析动作留在装配层，storage 只接受已解析的绝对路径。
 *
 * <p>解析口径与启动日志同源（{@link StartupConfigLogger#resolveAbsolute(String)}）：
 * 相对路径按进程工作目录解析、去尾随分隔符。不引入第二套规则，避免「日志里的数据根」
 * 与「实际写入的数据根」不一致。
 *
 * <p>仍然成立的例外：storage 只在「隔离键不得是单写者门协议文件」一处引用
 * {@link WriterGate#LOCK_FILE_NAME}（04 例外清单登记项）。启动门本身仍由 config 实现。
 */
@Configuration
public class StorageConfiguration {

    @Bean
    public FileStore fileStore(CangshuProperties properties) {
        Path dataRoot = Path.of(StartupConfigLogger.resolveAbsolute(properties.getDataRoot()));
        return new FileStore(dataRoot, WriterGate.LOCK_FILE_NAME);
    }
}
