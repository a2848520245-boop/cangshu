package com.cangshu.api;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;
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
import java.util.Map;
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
 * 任务 6 真实 HTTP 集成测试（05-接口契约 §3.5）：{@code DELETE /api/resources/{id}} → 204 软删。
 *
 * <p>覆盖四件事：软删后库里是不是「在回收站里」（两个时间戳齐备、内容与字节不动）、
 * 重复软删是否幂等且不刷新首次到期时刻、回收站资源对普通列表／详情／下载是否都不可见、
 * 以及缺资源（已硬删）与非 UUID 的负例。
 *
 * <p>前提：隔离 VM 内合成 PostgreSQL 17 已启动且 {@code cangshu_test} 库已按 {@code db/migration/V1__init.sql}
 * 与 {@code V2__search_indexes.sql} 初始化。
 */
@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.RANDOM_PORT, properties = {
        "spring.datasource.username=postgres",
        "spring.datasource.password=postgres",
        "cangshu.data-root=target/task6-test-data-root"
})
class DeleteResourceIntegrationTests extends IsolatedPostgresIntegrationTest {

    private static final java.nio.file.Path DATA_ROOT = java.nio.file.Path.of("target/task6-test-data-root");

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
        FileSystemUtils.deleteRecursively(DATA_ROOT);
    }

    // ────────────────────────── 用例 ──────────────────────────

    @Test
    @DisplayName("DELETE → 204：资源进回收站（两个时间戳齐备），内容与字节不动，普通列表／详情／下载均不可见")
    void softDeleteReturns204AndHidesResourceEverywhereButKeepsContent() throws Exception {
        JsonNode uploaded = upload("软删目标.bin", "任务6：软删只删引用".getBytes(StandardCharsets.UTF_8));
        UUID resourceId = UUID.fromString(uploaded.get("id").asText());
        UUID contentId = UUID.fromString(uploaded.get("contentId").asText());
        String digest = uploaded.get("hash").get("digest").asText();

        HttpResponse<String> deleted = delete("/api/resources/" + resourceId);
        assertEquals(204, deleted.statusCode(), "契约 §3.5：软删 → 204");
        assertEquals("", deleted.body(), "204 无响应体");

        // 回收站里的样子：行还在、两个时间戳齐备、到期时刻＝软删时刻＋保留期（默认 7 天）
        Map<String, Object> row = jdbc.queryForMap(
                "SELECT status, deleted_at, expire_at FROM cangshu_m1.resource WHERE id = ?", resourceId);
        assertEquals("DELETED", row.get("status"));
        assertNotNull(row.get("deleted_at"));
        assertNotNull(row.get("expire_at"));
        assertEquals("7 days", jdbc.queryForObject(
                "SELECT (expire_at - deleted_at)::text FROM cangshu_m1.resource WHERE id = ?",
                String.class, resourceId), "固定到期时刻＝软删时刻＋保留期（06 §8）");

        // 只删引用：内容行仍就绪、位置行与物理字节都在
        assertEquals("READY", jdbc.queryForObject(
                "SELECT status FROM cangshu_m1.content WHERE id = ?", String.class, contentId));
        assertEquals(1, countLocation(contentId));
        assertTrue(java.nio.file.Files.isRegularFile(blobPath(digest)), "软删不删字节（字节只由 GC 删）");

        // 回收站行计入保护引用计数（06 §8）
        assertEquals(1, jdbc.queryForObject(
                "SELECT count(*) FROM cangshu_m1.resource WHERE content_id = ?", Integer.class, contentId),
                "回收站行照样算保护引用，内容不因此进待回收");

        // 普通列表／详情／下载三处都不可见
        JsonNode list = mapper.readTree(get("/api/resources").body());
        assertEquals(0, list.get("items").size(), "回收站资源不出现在普通列表");
        assertEquals(0, list.get("total").asLong());
        assertError(get("/api/resources/" + resourceId), 404, "RESOURCE_NOT_FOUND");
        assertError(get("/api/resources/" + resourceId + "/content"), 404, "RESOURCE_NOT_FOUND");
    }

    @Test
    @DisplayName("重复软删幂等：再次 204 且首次到期时刻与软删时刻都不变")
    void repeatedSoftDeleteKeepsFirstExpiry() throws Exception {
        JsonNode uploaded = upload("重复软删.bin", "任务6：重复软删不刷新到期时刻".getBytes(StandardCharsets.UTF_8));
        UUID resourceId = UUID.fromString(uploaded.get("id").asText());

        assertEquals(204, delete("/api/resources/" + resourceId).statusCode());
        Map<String, Object> first = jdbc.queryForMap(
                "SELECT deleted_at, expire_at FROM cangshu_m1.resource WHERE id = ?", resourceId);

        assertEquals(204, delete("/api/resources/" + resourceId).statusCode(), "重复软删仍 204");
        Map<String, Object> second = jdbc.queryForMap(
                "SELECT deleted_at, expire_at FROM cangshu_m1.resource WHERE id = ?", resourceId);

        assertEquals(first.get("deleted_at"), second.get("deleted_at"), "首次软删时刻不被刷新");
        assertEquals(first.get("expire_at"), second.get("expire_at"), "保留期不被无限延长（06 §8）");
    }

    @Test
    @DisplayName("负例：未知 UUID 与已硬删的资源都返回 404 RESOURCE_NOT_FOUND")
    void missingResourceReturns404() throws Exception {
        JsonNode uploaded = upload("将被硬删.bin", "任务6：硬删后 404".getBytes(StandardCharsets.UTF_8));
        UUID resourceId = UUID.fromString(uploaded.get("id").asText());

        assertError(delete("/api/resources/" + UUID.randomUUID()), 404, "RESOURCE_NOT_FOUND");

        jdbc.update("DELETE FROM cangshu_m1.resource WHERE id = ?", resourceId);
        assertError(delete("/api/resources/" + resourceId), 404, "RESOURCE_NOT_FOUND",
                "已硬删：请求路径合法或非法都不得当成可删");
    }

    @Test
    @DisplayName("负例：非 UUID 的路径参数 → 400 INVALID_ARGUMENT")
    void nonUuidPathReturns400() throws Exception {
        assertError(delete("/api/resources/not-a-uuid"), 400, "INVALID_ARGUMENT");
    }

    @Test
    @DisplayName("软删不影响同内容的其他资源：一条进回收站，另一条照常可读可下载")
    void softDeletingOneResourceKeepsSiblingReadable() throws Exception {
        byte[] content = "任务6：同内容两条资源，删一条留一条".getBytes(StandardCharsets.UTF_8);
        JsonNode first = upload("副本一.bin", content);
        JsonNode second = upload("副本二.bin", content);
        assertEquals(first.get("contentId").asText(), second.get("contentId").asText(), "前置：两条资源共用一份内容");

        assertEquals(204, delete("/api/resources/" + first.get("id").asText()).statusCode());

        assertEquals(200, get("/api/resources/" + second.get("id").asText()).statusCode(),
                "另一条引用不受影响");
        assertEquals(200, get("/api/resources/" + second.get("id").asText() + "/content").statusCode());
        assertEquals(1, jdbc.queryForObject("SELECT count(*) FROM cangshu_m1.content", Integer.class),
                "内容行仍只有一条");
        assertEquals("READY", jdbc.queryForObject(
                "SELECT status FROM cangshu_m1.content", String.class), "仍有活跃引用 → 内容不进待回收");
    }

    // ────────────────────────── HTTP 辅助（真实 TCP） ──────────────────────────

    private String baseUrl() {
        return "http://127.0.0.1:" + port;
    }

    /** 经真实 multipart 上传并返回 201 响应体。 */
    private JsonNode upload(String filename, byte[] content) throws Exception {
        String boundary = "cangshu-task6-" + UUID.randomUUID();
        ByteArrayOutputStream body = new ByteArrayOutputStream();
        body.writeBytes(("--" + boundary + "\r\nContent-Disposition: form-data; name=\"file\"; filename=\""
                + filename + "\"\r\nContent-Type: application/octet-stream\r\n\r\n")
                .getBytes(StandardCharsets.UTF_8));
        body.writeBytes(content);
        body.writeBytes(("\r\n--" + boundary + "--\r\n").getBytes(StandardCharsets.UTF_8));
        HttpRequest request = HttpRequest.newBuilder(URI.create(baseUrl() + "/api/resources"))
                .header("Content-Type", "multipart/form-data; boundary=" + boundary)
                .POST(HttpRequest.BodyPublishers.ofByteArray(body.toByteArray()))
                .build();
        HttpResponse<String> response = http.send(request, HttpResponse.BodyHandlers.ofString());
        assertEquals(201, response.statusCode(), "前置：上传应成功 → " + response.body());
        return mapper.readTree(response.body());
    }

    private HttpResponse<String> get(String path) throws Exception {
        return http.send(HttpRequest.newBuilder(URI.create(baseUrl() + path)).GET().build(),
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

    private void assertError(HttpResponse<String> response, int expectedStatus, String expectedCode, String hint)
            throws Exception {
        assertEquals(expectedStatus, response.statusCode(), hint);
        JsonNode body = mapper.readTree(response.body());
        assertEquals(expectedCode, body.get("code").asText());
        assertTrue(!body.has("reason") || body.get("reason").isNull(), "非冲突错误体不携带 reason");
    }

    private java.nio.file.Path blobPath(String digest) {
        return java.nio.file.Path.of(DATA_ROOT.toString(), "sha256",
                digest.substring(0, 2), digest.substring(2, 4), digest);
    }

    private int countLocation(UUID contentId) {
        Integer value = jdbc.queryForObject(
                "SELECT count(*) FROM cangshu_m1.location WHERE content_id = ?", Integer.class, contentId);
        return value == null ? 0 : value;
    }
}
