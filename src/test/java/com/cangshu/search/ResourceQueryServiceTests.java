package com.cangshu.search;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.cangshu.search.ResourceQueryService.ResourcePage;
import com.cangshu.search.ResourceQueryService.ResourceView;
import com.cangshu.search.mapper.ResourceQueryMapper;
import com.cangshu.search.mapper.ResourceSummaryRow;
import java.time.OffsetDateTime;
import java.time.ZoneOffset;
import java.util.ArrayList;
import java.util.List;
import java.util.Optional;
import java.util.UUID;
import org.junit.jupiter.api.Test;

/**
 * {@link ResourceQueryService} 单元测试（任务 4）：读模型组装、tags jsonb 解析、
 * 时间归一化为 UTC、空白过滤参数透传为 null、分页 offset 计算、「未找到」返回空 Optional。
 * mapper 以手写桩替代（search 不依赖 catalog/storage，桩不引入 Mockito）。
 */
class ResourceQueryServiceTests {

    /** 记录调用参数的手写桩。 */
    static final class StubMapper implements ResourceQueryMapper {
        String name;
        String tag;
        int limit = -1;
        long offset = -1;
        UUID detailId;
        List<ResourceSummaryRow> rows = List.of();
        long total;
        ResourceSummaryRow detailRow;

        @Override
        public List<ResourceSummaryRow> search(String name, String tag, int limit, long offset) {
            this.name = name;
            this.tag = tag;
            this.limit = limit;
            this.offset = offset;
            return rows;
        }

        @Override
        public long countActive(String name, String tag) {
            return total;
        }

        @Override
        public ResourceSummaryRow findActiveById(UUID id) {
            this.detailId = id;
            return detailRow;
        }
    }

    private static ResourceSummaryRow row(String tagsJson, String hashAlgorithm) {
        ResourceSummaryRow row = new ResourceSummaryRow();
        row.setId(UUID.randomUUID());
        row.setName("季度报告.pdf");
        row.setSizeBytes(96L);
        row.setMimeType("application/pdf");
        row.setTags(tagsJson);
        row.setStatus("READY");
        row.setCreatedAt(OffsetDateTime.of(2026, 9, 19, 10, 0, 0, 0, ZoneOffset.ofHours(8)));
        row.setContentId(UUID.randomUUID());
        row.setHashAlgorithm(hashAlgorithm);
        row.setDigest("e9f546f7c4817a49a51a479ca92f11cda16578a7530ae00bf67b50f1de3ba588");
        return row;
    }

    @Test
    void listAssemblesPageAndNormalizesTagsAndTime() {
        StubMapper stub = new StubMapper();
        stub.rows = List.of(row("[\"合同\",\"加急\"]", "SHA-256"));
        stub.total = 123L;
        ResourceQueryService service = new ResourceQueryService(stub);

        ResourcePage page = service.list("报告", null, 3, 20);

        assertEquals("报告", stub.name, "name 过滤参数透传");
        assertNull(stub.tag, "未提供 tag 时透传 null");
        assertEquals(20, stub.limit);
        assertEquals(40L, stub.offset, "offset =（page-1）× size");
        assertEquals(123L, page.total());
        assertEquals(3, page.page());
        assertEquals(20, page.size());
        assertEquals(1, page.items().size());
        ResourceView view = page.items().get(0);
        assertEquals(List.of("合同", "加急"), view.tags(), "tags jsonb 解析为数组");
        assertEquals("SHA-256", view.hashAlgorithm(), "库内规范值原样保留（显示值映射属 api 层）");
        assertEquals(OffsetDateTime.of(2026, 9, 19, 2, 0, 0, 0, ZoneOffset.UTC), view.createdAt(),
                "createdAt 归一化为 UTC");
        assertEquals(96L, view.sizeBytes());
    }

    @Test
    void blankFiltersArePassedAsNull() {
        StubMapper stub = new StubMapper();
        stub.rows = List.of();
        ResourceQueryService service = new ResourceQueryService(stub);

        service.list("  ", "", 1, 20);

        assertNull(stub.name, "空白 name 视为未提供");
        assertNull(stub.tag, "空 tag 视为未提供");
        assertEquals(0L, stub.offset);
        assertTrue(pageOf(service, stub).items().isEmpty());
    }

    private static ResourcePage pageOf(ResourceQueryService service, StubMapper stub) {
        return service.list(null, null, 1, 20);
    }

    @Test
    void emptyTagsJsonParsesToEmptyList() {
        StubMapper stub = new StubMapper();
        stub.rows = List.of(row("[]", "SHA-256"), row(null, "SHA-256"));
        ResourceQueryService service = new ResourceQueryService(stub);

        ResourcePage page = service.list(null, null, 1, 20);

        assertTrue(page.items().get(0).tags().isEmpty());
        assertTrue(page.items().get(1).tags().isEmpty(), "tags 为 null 时按空数组处理");
    }

    @Test
    void detailReturnsViewOrEmptyOptional() {
        StubMapper stub = new StubMapper();
        ResourceQueryService service = new ResourceQueryService(stub);
        UUID id = UUID.randomUUID();

        assertTrue(service.detail(id).isEmpty(), "mapper 未命中 → 空 Optional");

        stub.detailRow = row("[]", "SHA-256");
        Optional<ResourceView> found = service.detail(id);
        assertTrue(found.isPresent());
        assertEquals(id, stub.detailId);
        assertEquals(stub.detailRow.getId(), found.get().id());
        assertEquals(stub.detailRow.getContentId(), found.get().contentId());
    }

    @Test
    void largePageOffsetDoesNotOverflow() {
        StubMapper stub = new StubMapper();
        ResourceQueryService service = new ResourceQueryService(stub);

        service.list(null, null, 2_000_000, 1_000_000);

        assertEquals(1_999_999_000_000L, stub.offset, "long 计算不溢出 int");
    }

    @Test
    void mapperRowsAreCopiedNotAliased() {
        StubMapper stub = new StubMapper();
        List<ResourceSummaryRow> mutable = new ArrayList<>();
        mutable.add(row("[]", "SHA-256"));
        stub.rows = mutable;
        ResourceQueryService service = new ResourceQueryService(stub);

        ResourcePage page = service.list(null, null, 1, 20);
        mutable.clear();

        assertEquals(1, page.items().size(), "结果列表独立于 mapper 返回列表");
    }
}
