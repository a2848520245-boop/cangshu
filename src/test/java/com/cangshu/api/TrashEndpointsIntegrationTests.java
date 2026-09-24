package com.cangshu.api;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.cangshu.IsolatedPostgresIntegrationTest;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.io.ByteArrayOutputStream;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.util.UUID;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.web.server.LocalServerPort;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.util.FileSystemUtils;

/**
 * 任务 28 真实 HTTP 集成测试（05-接口契约 §3.6–§3.8）：回收站列表、还原、清空。
 *
 * <p>重点是三处契约细节：① 回收站列表只给「已软删且未到期」的行并另带两个时间戳；
 * ② 分页上限与 §3.2 同口径（>200 即 400，2026-09-22 裁决定稿于 §3.6）；
 * ③ 清空**未带显式确认即 400 且一行不删**（08 §5 负例），确认后删行并让引用归零的内容进待回收。
 *
 * <p>前提：隔离 VM 内合成 PostgreSQL 17 已启动且 {@code cangshu_test} 库已按 {@code db/migration/V1__init.sql}
 * 与 {@code V2__search_indexes.sql} 初始化。
 */
@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.RANDOM_PORT, properties = {
        "spring.datasource.username=postgres",
        "spring.datasource.password=postgres",
        "cangshu.data-root=target/task28-test-data-root"
})
class TrashEndpointsIntegrationTests extends IsolatedPostgresIntegrationTest {

    @LocalServerPort
    int port;

    @Autowired
    JdbcTemplate jdbc;

    final HttpClient http = HttpClient.newHttpClient();
    final ObjectMapper mapper = new ObjectMapper();

    @BeforeEach
    void cleanState() throws Exception {
        jdbc.update("TRUNCATE cangshu_m1.resource, cangshu_m1.location, "
                + "cangshu_m1.content_conflict, cangshu_m1.content");
        FileSystemUtils.deleteRecursively(java.nio.file.Path.of("target/task28-test-data-root"));
    }

    // ────────────────────────── §3.6 回收站列表 ──────────────────────────

    @Test
    @DisplayName("回收站列表：只给已软删未到期的行，另带 deletedAt／expireAt，且不出现在普通列表")
    void trashListShowsOnlySoftDeletedUnexpiredRowsWithTimestamps() throws Exception {
        UUID kept = UUID.fromString(upload("保留.bin", "任务28：保留的活跃资源".getBytes(StandardCharsets.UTF_8))
                .get("id").asText());
        JsonNode target = upload("待删.bin", "任务28：进回收站的资源".getBytes(StandardCharsets.UTF_8));
        UUID trashed = UUID.fromString(target.get("id").asText());

        assertEquals(204, delete("/api/resources/" + trashed).statusCode());

        JsonNode trash = mapper.readTree(get("/api/resources/trash").body());
        assertEquals(1, trash.get("total").asLong());
        assertEquals(1, trash.get("page").asInt());
        assertEquals(20, trash.get("size").asInt());
        JsonNode item = trash.get("items").get(0);
        assertEquals(trashed.toString(), item.get("id").asText());
        assertEquals("DELETED", item.get("status").asText());
        assertTrue(item.hasNonNull("deletedAt"), "回收站项带 deletedAt（契约 §1）");
        assertTrue(item.hasNonNull("expireAt"), "回收站项带 expireAt（契约 §1）");
        assertTrue(item.get("deletedAt").asText().endsWith("Z"), "ISO-8601 UTC");
        assertFalse(item.has("contentId"), "列表项不输出 contentId");
        assertEquals("sha256", item.get("hash").get("algorithm").asText());

        JsonNode active = mapper.readTree(get("/api/resources").body());
        assertEquals(1, active.get("total").asLong(), "普通列表不含回收站资源");
        assertEquals(kept.toString(), active.get("items").get(0).get("id").asText());
    }

    @Test
    @DisplayName("回收站列表分页与 §3.2 同口径：size>200／size=0／page=0 → 400，size=200 → 200")
    void trashListPaginationIsBoundedByTwoHundred() throws Exception {
        assertError(get("/api/resources/trash?size=201"), 400, "INVALID_ARGUMENT");
        assertError(get("/api/resources/trash?size=0"), 400, "INVALID_ARGUMENT");
        assertError(get("/api/resources/trash?page=0"), 400, "INVALID_ARGUMENT");
        assertEquals(200, get("/api/resources/trash?size=200").statusCode());
    }

    @Test
    @DisplayName("已到期的回收站行不再出现在列表里（尚未到期才可见）")
    void expiredTrashRowIsNotListed() throws Exception {
        UUID resourceId = UUID.fromString(upload("已到期.bin", "任务28：到期不再可见".getBytes(StandardCharsets.UTF_8))
                .get("id").asText());
        assertEquals(204, delete("/api/resources/" + resourceId).statusCode());
        jdbc.update("UPDATE cangshu_m1.resource SET expire_at = now() - interval '1 second' WHERE id = ?",
                resourceId);

        JsonNode trash = mapper.readTree(get("/api/resources/trash").body());
        assertEquals(0, trash.get("total").asLong());
    }

    // ────────────────────────── §3.7 还原 ──────────────────────────

    @Test
    @DisplayName("还原：200 且回活跃列表；两个时间戳在库里被真正置空")
    void restoreBringsResourceBackToActiveList() throws Exception {
        UUID resourceId = UUID.fromString(upload("待还原.bin", "任务28：还原".getBytes(StandardCharsets.UTF_8))
                .get("id").asText());
        assertEquals(204, delete("/api/resources/" + resourceId).statusCode());

        HttpResponse<String> restored = post("/api/resources/" + resourceId + "/restore");
        assertEquals(200, restored.statusCode());
        JsonNode body = mapper.readTree(restored.body());
        assertEquals(resourceId.toString(), body.get("id").asText());
        assertEquals("READY", body.get("status").asText());
        assertFalse(body.has("deletedAt"), "还原后不再带 deletedAt");
        assertFalse(body.has("expireAt"));
        assertTrue(body.hasNonNull("contentId"), "详情形状带 contentId（引用关系展示）");

        assertEquals(0, mapper.readTree(get("/api/resources/trash").body()).get("total").asLong());
        assertEquals(200, get("/api/resources/" + resourceId).statusCode());
        assertTrue(jdbc.queryForObject(
                "SELECT (deleted_at IS NULL AND expire_at IS NULL) FROM cangshu_m1.resource WHERE id = ?",
                Boolean.class, resourceId), "库里两个时间戳必须真正为 NULL（不是跳过不写）");
    }

    @Test
    @DisplayName("还原负例：未知／已硬删 → 404；本就在活跃列表 → 200 幂等无操作")
    void restoreEdgeCases() throws Exception {
        assertError(post("/api/resources/" + UUID.randomUUID() + "/restore"), 404, "RESOURCE_NOT_FOUND");

        JsonNode uploaded = upload("活跃.bin", "任务28：已在活跃列表".getBytes(StandardCharsets.UTF_8));
        UUID resourceId = UUID.fromString(uploaded.get("id").asText());
        assertEquals(200, post("/api/resources/" + resourceId + "/restore").statusCode(), "已在活跃列表：幂等 200");

        jdbc.update("DELETE FROM cangshu_m1.resource WHERE id = ?", resourceId);
        assertError(post("/api/resources/" + resourceId + "/restore"), 404, "RESOURCE_NOT_FOUND",
                "已硬删 → 404（契约 §3.7）");
    }

    // ────────────────────────── §3.8 清空 ──────────────────────────

    @Test
    @DisplayName("清空未带显式确认：400 且一行不删（08 §5 负例）")
    void emptyTrashRequiresExplicitConfirmation() throws Exception {
        UUID resourceId = UUID.fromString(upload("待清空.bin", "任务28：清空负例".getBytes(StandardCharsets.UTF_8))
                .get("id").asText());
        assertEquals(204, delete("/api/resources/" + resourceId).statusCode());
        UUID contentId = jdbc.queryForObject(
                "SELECT content_id FROM cangshu_m1.resource WHERE id = ?", UUID.class, resourceId);

        assertError(delete("/api/resources/trash"), 400, "INVALID_ARGUMENT", "缺 confirm 参数");
        assertError(delete("/api/resources/trash?confirm=false"), 400, "INVALID_ARGUMENT", "confirm=false");
        assertError(delete("/api/resources/trash?confirm=1"), 400, "INVALID_ARGUMENT", "非 true 取值一律视为未确认");

        assertEquals(1, jdbc.queryForObject("SELECT count(*) FROM cangshu_m1.resource", Integer.class),
                "未确认时一行都不能删");
        assertEquals("READY", jdbc.queryForObject(
                "SELECT status FROM cangshu_m1.content WHERE id = ?", String.class, contentId),
                "未确认时内容态也不能动");
    }

    @Test
    @DisplayName("清空确认后：删行并返回 deletedCount；引用归零的内容进待回收")
    void emptyTrashDeletesRowsAndReleasesContent() throws Exception {
        UUID first = UUID.fromString(upload("清空一.bin", "任务28：清空甲".getBytes(StandardCharsets.UTF_8))
                .get("id").asText());
        UUID second = UUID.fromString(upload("清空二.bin", "任务28：清空乙".getBytes(StandardCharsets.UTF_8))
                .get("id").asText());
        assertEquals(204, delete("/api/resources/" + first).statusCode());
        assertEquals(204, delete("/api/resources/" + second).statusCode());
        UUID contentId = jdbc.queryForObject(
                "SELECT content_id FROM cangshu_m1.resource WHERE id = ?", UUID.class, first);

        HttpResponse<String> emptied = delete("/api/resources/trash?confirm=true");
        assertEquals(200, emptied.statusCode());
        JsonNode body = mapper.readTree(emptied.body());
        assertEquals(2, body.get("deletedCount").asInt(), "契约 §3.8 响应体只有 deletedCount");
        assertEquals(1, body.size(), "响应体不得多带字段");

        assertEquals(0, jdbc.queryForObject("SELECT count(*) FROM cangshu_m1.resource", Integer.class));
        assertEquals("RECLAIM_PENDING", jdbc.queryForObject(
                "SELECT status FROM cangshu_m1.content WHERE id = ?", String.class, contentId),
                "引用归零才置待回收（04 §5 ②、06 §8）");
        assertEquals(1, jdbc.queryForObject(
                "SELECT count(*) FROM cangshu_m1.location WHERE content_id = ?", Integer.class, contentId),
                "清空只删引用：位置行与字节交给 GC");

        HttpResponse<String> again = delete("/api/resources/trash?confirm=true");
        assertEquals(200, again.statusCode());
        assertEquals(0, mapper.readTree(again.body()).get("deletedCount").asInt(), "空回收站清空为 0");
    }

    // ────────────────────────── HTTP 辅助（真实 TCP） ──────────────────────────

    private String baseUrl() {
        return "http://127.0.0.1:" + port;
    }

    private JsonNode upload(String filename, byte[] content) throws Exception {
        String boundary = "cangshu-task28-" + UUID.randomUUID();
        ByteArrayOutputStream body = new ByteArrayOutputStream();
        body.writeBytes(("--" + boundary + "\r\nContent-Disposition: form-data; name=\"file\"; filename=\""
                + filename + "\"\r\nContent-Type: application/octet-stream\r\n\r\n")
                .getBytes(StandardCharsets.UTF_8));
        body.writeBytes(content);
        body.writeBytes(("\r\n--" + boundary + "--\r\n").getBytes(StandardCharsets.UTF_8));
        HttpResponse<String> response = http.send(HttpRequest.newBuilder(URI.create(baseUrl() + "/api/resources"))
                .header("Content-Type", "multipart/form-data; boundary=" + boundary)
                .POST(HttpRequest.BodyPublishers.ofByteArray(body.toByteArray()))
                .build(), HttpResponse.BodyHandlers.ofString());
        assertEquals(201, response.statusCode(), "前置：上传应成功 → " + response.body());
        return mapper.readTree(response.body());
    }

    private HttpResponse<String> get(String path) throws Exception {
        return http.send(HttpRequest.newBuilder(URI.create(baseUrl() + path)).GET().build(),
                HttpResponse.BodyHandlers.ofString());
    }

    private HttpResponse<String> post(String path) throws Exception {
        return http.send(HttpRequest.newBuilder(URI.create(baseUrl() + path))
                        .POST(HttpRequest.BodyPublishers.noBody()).build(),
                HttpResponse.BodyHandlers.ofString());
    }

    private HttpResponse<String> delete(String path) throws Exception {
        return http.send(HttpRequest.newBuilder(URI.create(baseUrl() + path)).DELETE().build(),
                HttpResponse.BodyHandlers.ofString());
    }

    private void assertError(HttpResponse<String> response, int expectedStatus, String expectedCode)
            throws Exception {
        assertError(response, expectedStatus, expectedCode, "");
    }

    private void assertError(HttpResponse<String> response, int expectedStatus, String expectedCode,
            String hint) throws Exception {
        assertEquals(expectedStatus, response.statusCode(), hint);
        assertEquals(expectedCode, mapper.readTree(response.body()).get("code").asText(), hint);
    }
}
