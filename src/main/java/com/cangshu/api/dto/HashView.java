package com.cangshu.api.dto;

/**
 * {@code hash} 对象（05-接口契约 §1）：显示值算法 ＋ 小写 64 位十六进制摘要。
 *
 * <p>归属 api：{@code hash.algorithm} 是**对外显示值**（04-架构与计划 §3 算法命名空间③），
 * 由 api 自己持有，不反向依赖 storage 的算法／路径实现（P0-3④ B）。库内规范值
 * {@code SHA-256} 与物理路径命名空间仍只属 storage／catalog 内部，三者不得互相替代。
 */
public record HashView(String algorithm, String digest) {

    /** 对外显示值：固定小写 {@code sha256}（05-接口契约 §1）。 */
    public static final String DISPLAY_ALGORITHM = "sha256";

    /** 上传响应、列表项、详情、回收站列表项四处共用的构造点：算法恒为显示值。 */
    public static HashView sha256(String digest) {
        return new HashView(DISPLAY_ALGORITHM, digest);
    }
}