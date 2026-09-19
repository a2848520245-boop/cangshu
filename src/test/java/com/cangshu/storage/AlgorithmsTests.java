package com.cangshu.storage;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;

import org.junit.jupiter.api.Test;

/** 算法命名空间：别名唯一规范化为 SHA-256；三处取值各司其职（04-架构与计划 §3）。 */
class AlgorithmsTests {

    @Test
    void normalizesAllSupportedAliasesToCanonical() {
        assertEquals("SHA-256", Algorithms.canonical("SHA-256"));
        assertEquals("SHA-256", Algorithms.canonical("sha-256"));
        assertEquals("SHA-256", Algorithms.canonical("SHA256"));
        assertEquals("SHA-256", Algorithms.canonical("Sha-256"));
        assertEquals("SHA-256", Algorithms.canonical(" sha256 "));
    }

    @Test
    void rejectsUnknownAlgorithms() {
        assertThrows(IllegalArgumentException.class, () -> Algorithms.canonical("md5"));
        assertThrows(IllegalArgumentException.class, () -> Algorithms.canonical(""));
        assertThrows(IllegalArgumentException.class, () -> Algorithms.canonical(null));
    }

    @Test
    void storageNamespaceDiffersFromCanonicalAndDisplay() {
        assertEquals("sha256", Algorithms.storageNamespace("SHA-256"));
        // 三处取值是三个不同字符串（规范值 ≠ 存储命名空间；显示值另行固定为 sha256）
        assertEquals("sha256", Algorithms.DISPLAY_SHA256);
        assertThrows(IllegalArgumentException.class, () -> Algorithms.storageNamespace("sha-256"));
        assertThrows(IllegalArgumentException.class, () -> Algorithms.storageNamespace("MD5"));
    }
}
