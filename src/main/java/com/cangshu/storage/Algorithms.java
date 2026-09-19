package com.cangshu.storage;

/**
 * 算法命名空间（04-架构与计划 §3）：三处取值各司其职，不得互相替代。
 *
 * <ul>
 *   <li>① 数据库 {@code content.hash_algorithm} 与并发锁键：规范值 {@link #CANONICAL_SHA256}；</li>
 *   <li>② 物理路径前缀：存储命名空间 {@link #STORAGE_NAMESPACE_SHA256}（由本类映射，与规范值不是同一字符串）；</li>
 *   <li>③ 对外 JSON {@code hash.algorithm}：显示值 {@link #DISPLAY_SHA256}。</li>
 * </ul>
 *
 * <p>任何算法别名（{@code sha-256}、{@code SHA256}、{@code Sha-256} 等）必须先经
 * {@link #canonical} 唯一规范化为规范值，才允许进入身份与锁；禁止大小写别名绕过锁。
 * M1 只支持 SHA-256。
 */
public final class Algorithms {

    /** 内容身份与并发锁键的规范值（库内取值）。 */
    public static final String CANONICAL_SHA256 = "SHA-256";

    /** 物理路径前缀的存储命名空间值（相对存储键首段）。 */
    public static final String STORAGE_NAMESPACE_SHA256 = "sha256";

    /** 对外 JSON 的显示值。 */
    public static final String DISPLAY_SHA256 = "sha256";

    private Algorithms() {
    }

    /**
     * 把算法别名唯一规范化为规范值；非 SHA-256 别名一律拒绝（M1 范围）。
     *
     * @throws IllegalArgumentException 空值或非 SHA-256 算法
     */
    public static String canonical(String algorithm) {
        if (algorithm == null) {
            throw new IllegalArgumentException("算法为空");
        }
        String collapsed = algorithm.strip().toLowerCase().replace("-", "");
        if ("sha256".equals(collapsed)) {
            return CANONICAL_SHA256;
        }
        throw new IllegalArgumentException("不支持的算法：" + algorithm + "（M1 仅支持 SHA-256）");
    }

    /** 规范值 → 存储命名空间（物理路径前缀）。 */
    public static String storageNamespace(String canonical) {
        if (CANONICAL_SHA256.equals(canonical)) {
            return STORAGE_NAMESPACE_SHA256;
        }
        throw new IllegalArgumentException("未知规范算法：" + canonical);
    }
}
