package com.cangshu.api;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.io.ByteArrayOutputStream;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.HashSet;
import java.util.HexFormat;
import java.util.Set;
import java.util.UUID;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.web.server.LocalServerPort;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.util.FileSystemUtils;

/**
 * 任务 4 真实 HTTP 集成测试（ACC-HTTP 任务级切片）：独立 Tomcat（随机端口）经 TCP 请求
 * {@code GET /api/resources}（列表／文件名／标签检索、分页、400 负例）与
 * {@code GET /api/resources/{id}}（详情、contentId 引用关系展示、404）。
 * 前提：本机 PostgreSQL 17 已运行且 {@code cangshu_test} 库已按 {@code db/migration/V1__init.sql}
 * 与 {@code V2__search_indexes.sql} 初始化。
 */
@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.RANDOM_PORT, properties = {
        "spring.datasource.url=jdbc:postgresql://127.0.0.1:5432/cangshu_test?currentSchema=cangshu_m1",
        "spring.datasource.username=postgres",
        "spring.datasource.password=postgres",
        "cangshu.data-root=target/task4-test-data-root"
})
class ResourceQueryIntegrationTests {

    @LocalServerPort
    int port;

    @Autowired
    JdbcTemplate jdbc;

    final HttpClient http = HttpClient.newHttpClient();
    final ObjectMapper mapper = new ObjectMapper();

    @BeforeEach
    void cleanState() throws Exception {
        jdbc.update("TRUNCATE cangshu_m1.resource, cangshu_m1.location, cangshu_m1.content_conflict, cangshu_m1.content");
        FileSystemUtils.deleteRecursively(java.nio.file.Path.of("target/task4-test-data-root"));
    }

    // ────────────────────────── HTTP 辅助（真实 TCP） ──────────────────────────

    private String baseUrl() {
        return "http://127.0.0.1:" + port;
    }

    static byte[] multipartBody(String boundary, String filename, String contentType, byte[] content) {
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        out.writeBytes(("--" + boundary + "\r\nContent-Disposition: form-data; name=\"file\"; filename=\""
                + filename + "\"\r\nContent-Type: " + contentType + "\r\n\r\n").getBytes(StandardCharsets.UTF_8));
        out.writeBytes(content);
        out.writeBytes(("\r\n--" + boundary + "--\r\n").getBytes(StandardCharsets.UTF_8));
        return out.toByteArray();
    }

    /** 经真实 multipart 上传并返回 201 响应体。 */
    private JsonNode upload(String filename, byte[] content) throws Exception {
        String boundary = "cangshu-task4-" + UUID.randomUUID();
        HttpRequest request = HttpRequest.newBuilder(URI.create(baseUrl() + "/api/resources"))
                .header("Content-Type", "multipart/form-data; boundary=" + boundary)
                .POST(HttpRequest.BodyPublishers.ofByteArray(
                        multipartBody(boundary, filename, "application/octet-stream", content)))
                .build();
        HttpResponse<String> response = http.send(request, HttpResponse.BodyHandlers.ofString());
        assertEquals(201, response.statusCode(), "前置：上传应成功 → " + response.body());
        return mapper.readTree(response.body());
    }

    private HttpResponse<String> get(String path) throws Exception {
        HttpRequest request = HttpRequest.newBuilder(URI.create(baseUrl() + path)).GET().build();
        return http.send(request, HttpResponse.BodyHandlers.ofString());
    }

    private static void assertErrorBody(HttpResponse<String> response, int expectedStatus,
            String expectedCode) throws Exception {
        assertEquals(expectedStatus, response.statusCode());
        JsonNode body = mapper().readTree(response.body());
        assertEquals(expectedCode, body.get("code").asText());
        assertTrue(!body.has("reason") || body.get("reason").isNull(),
                "非冲突错误体不携带 reason");
    }

    private static ObjectMapper mapper() {
        return new ObjectMapper();
    }

    private static void pauseDistinctMillis() throws InterruptedException {
        Thread.sleep(15);
    }

    // ────────────────────────── 用例 ──────────────────────────

    @Test
    void emptyListReturnsContractEnvelope() throws Exception {
        HttpResponse<String> response = get("/api/resources");
        assertEquals(200, response.statusCode());
        JsonNode body = mapper.readTree(response.body());
        assertEquals(0, body.get("items").size());
        assertEquals(0, body.get("total").asLong());
        assertEquals(1, body.get("page").asInt());
        assertEquals(20, body.get("size").asInt());
    }

    @Test
    void listItemsUseContractResourceShapeWithoutContentId() throws Exception {
        byte[] content = "任务4列表形状核对".getBytes(StandardCharsets.UTF_8);
        upload("形状核对-甲.txt", content);
        pauseDistinctMillis();
        JsonNode newest = upload("形状核对-乙.txt", "另一个文件".getBytes(StandardCharsets.UTF_8));

        HttpResponse<String> response = get("/api/resources");
        assertEquals(200, response.statusCode());
        JsonNode body = mapper.readTree(response.body());
        assertEquals(2, body.get("total").asLong());
        assertEquals(2, body.get("items").size());

        JsonNode first = body.get("items").get(0);
        assertEquals("形状核对-乙.txt", first.get("name").asText(), "UUIDv7 时间有序：新资源在前");
        assertEquals(newest.get("id").asText(), first.get("id").asText());
        assertEquals(newest.get("sizeBytes").asLong(), first.get("sizeBytes").asLong());
        assertEquals("application/octet-stream", first.get("mimeType").asText());
        assertEquals("sha256", first.get("hash").get("algorithm").asText(), "对外显示值 sha256");
        assertEquals(newest.get("hash").get("digest").asText(), first.get("hash").get("digest").asText(),
                "列表摘要与上传摘要一致");
        assertEquals(0, first.get("tags").size());
        assertEquals("READY", first.get("status").asText());
        assertTrue(first.get("createdAt").asText().endsWith("Z"), "ISO-8601 UTC");
        assertFalse(first.has("contentId"), "列表项为契约 §1 Resource 形状，不带 contentId");
        assertFalse(first.has("deduplicated"), "列表项不携带上传响应专用字段");
        assertFalse(first.has("deletedAt"), "普通列表不带回收站字段");
    }

    @Test
    void nameSearchIsCaseInsensitiveContains() throws Exception {
        upload("MeetingNotes-Alpha.txt", "甲".getBytes(StandardCharsets.UTF_8));
        upload("photo-2024.jpg", "乙".getBytes(StandardCharsets.UTF_8));

        HttpResponse<String> hit = get("/api/resources?name=notes-alpha");
        assertEquals(200, hit.statusCode());
        JsonNode hitBody = mapper.readTree(hit.body());
        assertEquals(1, hitBody.get("total").asLong(), "文件名包含匹配、大小写不敏感");
        assertEquals("MeetingNotes-Alpha.txt", hitBody.get("items").get(0).get("name").asText());

        HttpResponse<String> miss = get("/api/resources?name=zzz-not-exist");
        assertEquals(0, mapper.readTree(miss.body()).get("total").asLong());

        HttpResponse<String> blank = get("/api/resources?name=");
        assertEquals(2, mapper.readTree(blank.body()).get("total").asLong(), "空 name 视为未过滤");
    }

    @Test
    void paginationReturnsRequestedPageAndTotals() throws Exception {
        JsonNode first = upload("分页-1.txt", "1".getBytes(StandardCharsets.UTF_8));
        pauseDistinctMillis();
        JsonNode second = upload("分页-2.txt", "2".getBytes(StandardCharsets.UTF_8));
        pauseDistinctMillis();
        upload("分页-3.txt", "3".getBytes(StandardCharsets.UTF_8));

        HttpResponse<String> page1 = get("/api/resources?page=1&size=2");
        JsonNode body1 = mapper.readTree(page1.body());
        assertEquals(3, body1.get("total").asLong());
        assertEquals(1, body1.get("page").asInt());
        assertEquals(2, body1.get("size").asInt());
        assertEquals(2, body1.get("items").size());

        HttpResponse<String> page2 = get("/api/resources?page=2&size=2");
        JsonNode body2 = mapper.readTree(page2.body());
        assertEquals(1, body2.get("items").size());
        assertEquals(3, body2.get("total").asLong());

        Set<String> seen = new HashSet<>();
        body1.get("items").forEach(n -> seen.add(n.get("id").asText()));
        body2.get("items").forEach(n -> seen.add(n.get("id").asText()));
        assertEquals(3, seen.size(), "三页并集覆盖全部资源且不重复");
        assertTrue(seen.contains(first.get("id").asText()));
        assertTrue(seen.contains(second.get("id").asText()));

        HttpResponse<String> page3 = get("/api/resources?page=3&size=2");
        JsonNode body3 = mapper.readTree(page3.body());
        assertEquals(0, body3.get("items").size());
        assertEquals(3, body3.get("total").asLong(), "total 与页内条数无关");
    }

    @Test
    void invalidPaginationParamsReturn400() throws Exception {
        for (String query : new String[] {"page=0", "page=-1", "size=0", "size=-3", "page=abc", "size=1.5"}) {
            assertErrorBody(get("/api/resources?" + query), 400, "INVALID_ARGUMENT");
        }
    }

    @Test
    void detailReturnsContentAssociationAnd404ForUnknown() throws Exception {
        byte[] content = "任务4详情引用关系".getBytes(StandardCharsets.UTF_8);
        JsonNode uploaded = upload("详情核对.txt", content);

        HttpResponse<String> detail = get("/api/resources/" + uploaded.get("id").asText());
        assertEquals(200, detail.statusCode());
        JsonNode body = mapper.readTree(detail.body());
        assertEquals("详情核对.txt", body.get("name").asText());
        assertEquals(uploaded.get("contentId").asText(), body.get("contentId").asText(),
                "详情展示内容关联（引用关系展示，REQ-M1-06）");
        assertEquals(uploaded.get("hash").get("digest").asText(), body.get("hash").get("digest").asText());
        assertEquals(0, body.get("tags").size());
        assertTrue(body.get("createdAt").asText().endsWith("Z"));

        assertErrorBody(get("/api/resources/" + UUID.randomUUID()), 404, "RESOURCE_NOT_FOUND");
    }

    @Test
    void malformedResourceIdReturns400() throws Exception {
        assertErrorBody(get("/api/resources/not-a-uuid"), 400, "INVALID_ARGUMENT");
    }

    @Test
    void deletedResourcesHiddenFromListAndDetail() throws Exception {
        JsonNode keep = upload("保留.txt", "保留".getBytes(StandardCharsets.UTF_8));
        pauseDistinctMillis();
        JsonNode removed = upload("进回收站.txt", "回收".getBytes(StandardCharsets.UTF_8));

        // 直接置软删态（软删 API 属任务 6；此处验证列表／详情的可见性规则）
        jdbc.update("UPDATE cangshu_m1.resource SET status = 'DELETED', deleted_at = now(), "
                + "expire_at = now() + interval '7 days' WHERE id = ?", UUID.fromString(removed.get("id").asText()));

        HttpResponse<String> list = get("/api/resources");
        JsonNode listBody = mapper.readTree(list.body());
        assertEquals(1, listBody.get("total").asLong(), "回收站资源不出现在普通列表");
        assertEquals(keep.get("id").asText(), listBody.get("items").get(0).get("id").asText());

        HttpResponse<String> detail = get("/api/resources/" + removed.get("id").asText());
        assertErrorBody(detail, 404, "RESOURCE_NOT_FOUND");

        HttpResponse<String> keepDetail = get("/api/resources/" + keep.get("id").asText());
        assertEquals(200, keepDetail.statusCode(), "未删资源详情不受影响");
    }

    @Test
    void tagSearchFiltersByJsonbContainmentAndCombinesWithName() throws Exception {
        JsonNode urgent = upload("合同-扫描件.pdf", "甲".getBytes(StandardCharsets.UTF_8));
        pauseDistinctMillis();
        JsonNode plain = upload("合同-备份.pdf", "乙".getBytes(StandardCharsets.UTF_8));
        jdbc.update("UPDATE cangshu_m1.resource SET tags = CAST(? AS jsonb) WHERE id = ?",
                "[\"合同\",\"加急\"]", UUID.fromString(urgent.get("id").asText()));
        jdbc.update("UPDATE cangshu_m1.resource SET tags = CAST(? AS jsonb) WHERE id = ?",
                "[\"合同\"]", UUID.fromString(plain.get("id").asText()));

        HttpResponse<String> byTag = get("/api/resources?tag=加急");
        JsonNode byTagBody = mapper.readTree(byTag.body());
        assertEquals(1, byTagBody.get("total").asLong(), "标签过滤命中含该标签的资源");
        assertEquals(urgent.get("id").asText(), byTagBody.get("items").get(0).get("id").asText());
        assertEquals(java.util.List.of("合同", "加急"), tagsOf(byTagBody.get("items").get(0)));

        HttpResponse<String> miss = get("/api/resources?tag=不存在的标签");
        assertEquals(0, mapper.readTree(miss.body()).get("total").asLong());

        HttpResponse<String> combined = get("/api/resources?name=合同&tag=加急");
        JsonNode combinedBody = mapper.readTree(combined.body());
        assertEquals(1, combinedBody.get("total").asLong(), "name 与 tag 同时给出按 AND 组合");
        assertEquals(urgent.get("id").asText(), combinedBody.get("items").get(0).get("id").asText());

        HttpResponse<String> combinedMiss = get("/api/resources?name=备份&tag=加急");
        assertEquals(0, mapper.readTree(combinedMiss.body()).get("total").asLong(), "AND 组合不满足即不命中");

        assertNotEquals(urgent.get("id").asText(), plain.get("id").asText());
    }

    private static java.util.List<String> tagsOf(JsonNode item) {
        java.util.List<String> tags = new java.util.ArrayList<>();
        item.get("tags").forEach(n -> tags.add(n.asText()));
        return tags;
    }

    private static String sha256Hex(byte[] content) throws Exception {
        MessageDigest digest = MessageDigest.getInstance("SHA-256");
        return HexFormat.of().formatHex(digest.digest(content));
    }
}
