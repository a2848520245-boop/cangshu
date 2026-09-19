package com.cangshu.ingest;

import java.nio.file.Path;

/**
 * 流式接收结果：临时文件已落数据根临时区、摘要已边收边算完成（锁外，04-架构与计划 §1 ingest）。
 *
 * @param temp       临时文件绝对路径（与正式区同一文件系统）
 * @param algorithm  内容身份算法规范值（已归一，如 {@code SHA-256}）
 * @param digest     小写十六进制摘要
 * @param sizeBytes  实际接收字节数
 */
public record StagedUpload(Path temp, String algorithm, String digest, long sizeBytes) {
}
