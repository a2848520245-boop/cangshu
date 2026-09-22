package com.cangshu.api.dto;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotEquals;

import com.cangshu.catalog.CatalogService;
import com.cangshu.search.ResourceQueryService;
import java.time.OffsetDateTime;
import java.time.ZoneOffset;
import java.util.List;
import java.util.UUID;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

/**
 * 对外 {@code hash.algorithm} 显示值（P0-3④ B）：上传、列表、详情、回收站四处一律小写
 * {@code sha256}，且不等于库内规范值 {@code SHA-256}——显示值由 api 自己组装，
 * API DTO 不引用 storage 的算法类（结构断言见 {@code com.cangshu.arch.DependencyStructureTests}）。
 */
class HashDisplayTests {

    private static final String CANONICAL_IN_DB = "SHA-256";

    @Test
    @DisplayName("显示值常量固定为小写 sha256，与库内规范值 SHA-256 不是同一字符串")
    void displayConstantIsLowercaseNamespace() {
        assertEquals("sha256", HashView.DISPLAY_ALGORITHM);
        assertNotEquals(CANONICAL_IN_DB, HashView.DISPLAY_ALGORITHM, "显示值不得回灌库内规范值");
    }

    @Test
    @DisplayName("上传响应 hash.algorithm 为 sha256")
    void uploadResponseUsesDisplayValue() {
        UploadResponse response = UploadResponse.from(new CatalogService.UploadResult(
                UUID.randomUUID(), UUID.randomUUID(), "样本.bin", "application/octet-stream",
                3L, CANONICAL_IN_DB, "ab".repeat(32), false, false, now()));

        assertEquals("sha256", response.hash().algorithm());
        assertEquals("ab".repeat(32), response.hash().digest());
    }

    @Test
    @DisplayName("列表项／详情／回收站列表项三处视图的 hash.algorithm 均为 sha256")
    void resourceViewsUseDisplayValue() {
        ResourceQueryService.ResourceView view = view();

        assertEquals("sha256", ResourceResponse.listItem(view).hash().algorithm());
        assertEquals("sha256", ResourceResponse.detail(view).hash().algorithm());
        assertEquals("sha256", ResourceResponse.trashItem(view).hash().algorithm());

        ResourceListResponse list = ResourceListResponse.from(
                new ResourceQueryService.ResourcePage(List.of(view), 1L, 1, 20));
        ResourceListResponse trash = ResourceListResponse.fromTrash(
                new ResourceQueryService.ResourcePage(List.of(view), 1L, 1, 20));
        assertEquals("sha256", list.items().get(0).hash().algorithm());
        assertEquals("sha256", trash.items().get(0).hash().algorithm());
    }

    /** 读视图的算法字段带库内规范值：DTO 必须把它换成显示值，不能原样透传。 */
    private static ResourceQueryService.ResourceView view() {
        return new ResourceQueryService.ResourceView(UUID.randomUUID(), "样本.bin", 3L,
                "application/octet-stream", List.of(), "READY", now(), UUID.randomUUID(),
                CANONICAL_IN_DB, "ab".repeat(32), null, null);
    }

    private static OffsetDateTime now() {
        return OffsetDateTime.now(ZoneOffset.UTC);
    }
}
