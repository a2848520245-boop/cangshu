package com.cangshu.migration;

/**
 * 启动只读迁移核对失败。
 *
 * <p>这是一个单独的异常类型，使应用入口能稳定地把所有迁移台账／结构漂移映射为运行手册规定的
 * 退出码 3，而不把数据库连接、脚本目录或结构不符误报成普通启动故障。
 */
public final class MigrationVerificationException extends RuntimeException {

    public MigrationVerificationException(String message) {
        super(message);
    }

    public MigrationVerificationException(String message, Throwable cause) {
        super(message, cause);
    }
}