package com.cangshu.common;

import java.nio.file.Path;

/**
 * 上传暂存的纯数据载荷（P0-3④ A）：一次流式接收的结果——临时文件已落数据根临时区、
 * 摘要已边收边算完成、算法已归一。
 *
 * <p>放在 {@code common} 是因为它**不隶属任何业务模块**：ingest 生产它（锁外落盘），
 * catalog 消费它（锁内移动并登记），api 只在两者之间转发。若把它挂在 ingest 上，
 * 就会出现 {@code catalog → ingest} 的反向依赖（04-架构与计划 §1 禁止）；若挂在
 * {@code storage.FileStore} 上，api 又会依赖 storage 的字节实现。因此它只是无行为的
 * 值对象：不含锁、不含事务、不解析路径、不判冲突。
 *
 * @param temp               临时文件绝对路径（与正式内容区同一文件系统，移动才成立）
 * @param canonicalAlgorithm 内容身份算法的**规范值**（已归一，如 {@code SHA-256}；
 *                           不是对外显示值 {@code sha256}，也不是路径命名空间）
 * @param digest             小写十六进制摘要
 * @param sizeBytes          实际接收字节数
 */
public record StagedUpload(Path temp, String canonicalAlgorithm, String digest, long sizeBytes) {
}