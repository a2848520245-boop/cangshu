package com.cangshu.storage;

import java.security.MessageDigest;

/**
 * 流式摘要器接缝（08-验收规范 §2 测试夹具要求：测试构建装配可替换的摘要器，正式制品不装配假摘要夹具）。
 *
 * <p>生产装配为 {@link Sha256Digester}；测试构建可提供替换实现（注入假摘要驱动哈希冲突路径），
 * 正式配置不提供任何制造假摘要的运行期开关。
 */
public interface Digestor {

    /** 内容身份算法的规范值（已归一，进入身份与锁）。 */
    String canonicalAlgorithm();

    /** 新建一个流式摘要器实例（每份上传独立使用）。 */
    MessageDigest create();
}
