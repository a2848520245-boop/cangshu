package com.cangshu.config;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.cangshu.api.dto.ResourceResponse;
import com.cangshu.api.dto.HashView;
import com.cangshu.api.dto.UploadResponse;
import com.cangshu.search.ResourceQueryService;
import com.cangshu.storage.Algorithms;
import java.time.Duration;
import java.time.OffsetDateTime;
import java.time.ZoneOffset;
import java.util.List;
import java.util.UUID;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

/**
 * 配置绑定层的口径校验与对外显示值一致性。
 *
 * <p>前者对应评审 L-7（`07-运行手册 §1`「保留期允许测试值 0，禁止负数」此前未实现）；
 * 后者对应评审 L-1（算法命名空间③ 的显示值在 api 层被硬编码而存在漂移风险）；
 * P0-3④ B 后该显示值由 api 侧唯一常量 {@link HashView#DISPLAY_ALGORITHM} 持有，
 * api 不再引用 storage 的算法类（结构断言见 {@code com.cangshu.arch.DependencyStructureTests}）。
 */
class CangshuPropertiesTests {

    @Test
    @DisplayName("trash.retention 禁止负数（L-7）：负值在绑定层被拒绝，0 与正值放行")
    void negativeRetentionIsRejectedAtBindingLayer() {
        CangshuProperties properties = new CangshuProperties();

        assertThrows(IllegalArgumentException.class, () -> properties.getTrash().setRetention(Duration.ofDays(-1)));
        assertThrows(IllegalArgumentException.class, () -> properties.getTrash().setRetention(Duration.ofSeconds(-1)));

        properties.getTrash().setRetention(Duration.ZERO);
        assertEquals(Duration.ZERO, properties.getTrash().getRetention(), "测试值 0 必须允许");

        properties.getTrash().setRetention(Duration.ofDays(7));
        assertEquals(Duration.ofDays(7), properties.getTrash().getRetention(), "默认值 7d 必须允许");

        assertTrue(properties.getUpload().getMaxSize().toBytes() > 0, "上传上限默认值应为正");
        assertEquals("SHA-256", Algorithms.CANONICAL_SHA256, "库内规范值");
    }

    @Test
    @DisplayName("协议的锁键常量不在绑定面上（环境变量与配置文件都无法覆盖）")
    void protocolLockKeysAreStaticConstants() {
        assertEquals(20260918L, CangshuProperties.MIGRATION_LOCK_KEY);
        assertEquals(20260919L, CangshuProperties.WRITER_LOCK_KEY);
    }

    @Test
    @DisplayName("对外 hash.algorithm 使用算法命名空间③ 的显示值（L-1），由 api 侧唯一常量持有")
    void hashAlgorithmUsesDisplayNamespace() {
        UUID id = UUID.randomUUID();
        OffsetDateTime now = OffsetDateTime.now(ZoneOffset.UTC);

        UploadResponse upload = new UploadResponse(id, "样本.bin", 3L, "application/octet-stream",
                HashView.sha256("ab".repeat(32)),
                List.of(), "READY", now, false, UUID.randomUUID());
        assertEquals(HashView.DISPLAY_ALGORITHM, upload.hash().algorithm());
        assertEquals("sha256", upload.hash().algorithm(), "契约 05 §1 固定为显示值 sha256");

        ResourceQueryService.ResourceView view = new ResourceQueryService.ResourceView(
                id, "样本.bin", 3L, "application/octet-stream", List.of(), "READY", now,
                UUID.randomUUID(), Algorithms.CANONICAL_SHA256, "ab".repeat(32), null, null);
        ResourceResponse listItem = ResourceResponse.listItem(view);
        assertEquals(HashView.DISPLAY_ALGORITHM, listItem.hash().algorithm());
        assertEquals(HashView.DISPLAY_ALGORITHM, ResourceResponse.detail(view).hash().algorithm());
    }
}
