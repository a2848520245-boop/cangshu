package com.cangshu.api;

import static org.junit.jupiter.api.Assertions.assertArrayEquals;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.cangshu.storage.Digestor;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.io.ByteArrayOutputStream;
import java.net.URI;
import java.net.URLDecoder;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.MessageDigest;
import java.util.HexFormat;
import java.util.UUID;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.web.server.LocalServerPort;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.util.FileSystemUtils;

/**
 * 任务 5 真实 HTTP 集成测试（ACC-HTTP 任务级切片；05-接口契约 §3.4／REQ-M1-07）：独立 Tomcat
 * （随机端口）经 TCP 请求 {@code GET /api/resources/{id}/content}，覆盖：
 * 下载字节与上传摘要恒等（EV-04 §7.1 遗留在本包闭合）、{@code Content-Disposition}
 * attachment／inline 两种形态（inline=1 只改响应头不改字节）、inline 非法值 400、
 * 404（不存在／软删不可见）、字节缺失拒绝下载（500，绝不返回空文件）、去重共享内容可下载。
 * 前提：本机 PostgreSQL 17 已运行且 {@code cangshu_test} 库已按 V1+V2 初始化。
 */
@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.RANDOM_PORT, properties = {
        "spring.datasource.url=jdbc:postgresql://127.0.0.1:5432/cangshu_test?currentSchema=cangshu_m1",
        "spring.datasource.username=postgres",
        "spring.datasource.password=postgres",
        "cangshu.data-root=target/task5-test-data-root"
})
class DownloadFlowIntegrationTests {

    @LocalServerPort
    int port;

    @Autowired
    JdbcTemplate jdbc;

    final HttpClient http = HttpClient.newHttpClient();
    final ObjectMapper mapper = new ObjectMapper();

    @BeforeEach
    void cleanState() throws Exception {
        jdbc.update("TRUNCATE cangshu_m1.resource, cangshu_m1.location, cangshu_m1.content_conflict, cangshu_m1.content");
        FileSystemUtils.deleteRecursively(Path.of("target/task5-test-data-root"));
    }

    // ────────────────────────── HTTP 辅助 ──────────────────────────

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

    private JsonNode upload(String filename, String contentType, byte[] content) throws Exception {
        String boundary = "cangshu-dl-" + UUID.randomUUID();
        HttpRequest request = HttpRequest.newBuilder(URI.create(baseUrl() + "/api/resources"))
                .header("Content-Type", "multipart/form-data; boundary=" + boundary)
                .POST(HttpRequest.BodyPublishers.ofByteArray(
                        multipartBody(boundary, filename, contentType, content)))
                .build();
        HttpResponse<String> response = http.send(request, HttpResponse.BodyHandlers.ofString());
        assertEquals(201, response.statusCode(), "前置：上传成功 → " + response.body());
        return mapper.readTree(response.body());
    }

    private HttpResponse<byte[]> download(UUID id, String query) throws Exception {
        String url = baseUrl() + "/api/resources/" + id + "/content" + (query == null ? "" : query);
        return http.send(HttpRequest.newBuilder(URI.create(url)).GET().build(),
                HttpResponse.BodyHandlers.ofByteArray());
    }

    private HttpResponse<String> getString(String path) throws Exception {
        return http.send(HttpRequest.newBuilder(URI.create(baseUrl() + path)).GET().build(),
                HttpResponse.BodyHandlers.ofString());
    }

    private static String sha256Hex(byte[] content) throws Exception {
        return HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(content));
    }

    /** filename*=UTF-8''%XX 形态解码（RFC 5987/6266）。 */
    private static String filenameStarOf(String contentDisposition) {
        Matcher match = Pattern.compile("filename\\*=UTF-8''([^;]+)").matcher(contentDisposition);
        assertTrue(match.find(), "响应头必须带 filename*=UTF-8'' 形态：" + contentDisposition);
        return URLDecoder.decode(match.group(1), StandardCharsets.UTF_8);
    }

    // ────────────────────────── 用例 ──────────────────────────

    @Test
    void downloadBytesAreIdenticalToUploadWithAttachmentDisposition() throws Exception {
        byte[] content = "ACC-G2 下载比对：下载字节与上传源文件 SHA-256 恒等（EV-04 §7.1 闭合）"
                .getBytes(StandardCharsets.UTF_8);
        String sourceDigest = sha256Hex(content);
        JsonNode uploaded = upload("报告 第一版.txt", "text/plain", content);
        UUID id = UUID.fromString(uploaded.get("id").asText());
        String uploadedDigest = uploaded.get("hash").get("digest").asText();
        assertEquals(sourceDigest, uploadedDigest, "前置：上传响应摘要＝源文件 SHA-256");

        HttpResponse<byte[]> response = download(id, null);
        assertEquals(200, response.statusCode());
        String disposition = response.headers().firstValue("Content-Disposition").orElse("");
        assertTrue(disposition.startsWith("attachment;"), "默认下载形态＝attachment：" + disposition);
        assertEquals("报告 第一版.txt", filenameStarOf(disposition), "filename* 解码＝原始文件名");
        assertEquals("text/plain", response.headers().firstValue("Content-Type").orElse(""),
                "Content-Type＝上传声明值");
        assertEquals(content.length,
                Long.parseLong(response.headers().firstValue("Content-Length").orElse("-1")));
        assertEquals(sourceDigest, sha256Hex(response.body()), "下载字节 SHA-256 与上传摘要恒等");
        assertArrayEquals(content, response.body(), "下载字节与源文件逐字节一致");
    }

    @Test
    void inlineParameterOnlyChangesDispositionNotBytes() throws Exception {
        byte[] content = "inline=1 只改响应头形态，不改字节来源".getBytes(StandardCharsets.UTF_8);
        String digest = sha256Hex(content);
        JsonNode uploaded = upload("预览.pdf", "application/pdf", content);
        UUID id = UUID.fromString(uploaded.get("id").asText());

        HttpResponse<byte[]> attachment = download(id, null);
        HttpResponse<byte[]> inline = download(id, "?inline=1");
        assertEquals(200, inline.statusCode());
        String inlineDisposition = inline.headers().firstValue("Content-Disposition").orElse("");
        assertTrue(inlineDisposition.startsWith("inline;"), "inline=1 → inline 形态：" + inlineDisposition);
        assertEquals("预览.pdf", filenameStarOf(inlineDisposition));
        assertEquals(digest, sha256Hex(inline.body()), "inline 与 attachment 字节来源相同");
        assertArrayEquals(attachment.body(), inline.body());
    }

    @Test
    void inlineNonOneValueReturns400() throws Exception {
        JsonNode uploaded = upload("样本.bin", "application/octet-stream", "x".getBytes(StandardCharsets.UTF_8));
        UUID id = UUID.fromString(uploaded.get("id").asText());
        HttpResponse<String> response = getString("/api/resources/" + id + "/content?inline=true");
        assertEquals(400, response.statusCode());
        assertEquals("INVALID_ARGUMENT", mapper.readTree(response.body()).get("code").asText());
    }

    @Test
    void unknownResourceReturns404() throws Exception {
        HttpResponse<String> response = getString(
                "/api/resources/" + UUID.randomUUID() + "/content");
        assertEquals(404, response.statusCode());
        assertEquals("RESOURCE_NOT_FOUND", mapper.readTree(response.body()).get("code").asText());
    }

    @Test
    void nonUuidIdReturns400() throws Exception {
        HttpResponse<String> response = getString("/api/resources/not-a-uuid/content");
        assertEquals(400, response.statusCode());
        assertEquals("INVALID_ARGUMENT", mapper.readTree(response.body()).get("code").asText());
    }

    @Test
    void softDeletedResourceIsNotDownloadable() throws Exception {
        JsonNode uploaded = upload("已软删.bin", "application/octet-stream",
                "回收站中的资源对普通下载不可见".getBytes(StandardCharsets.UTF_8));
        UUID id = UUID.fromString(uploaded.get("id").asText());
        // 任务 6 未实现软删端点：以 SQL 模拟合法软删态（等价约束要求两个时间戳非空）
        jdbc.update("UPDATE cangshu_m1.resource SET status = 'DELETED', deleted_at = now(), expire_at = now() "
                + "WHERE id = ?", id);
        HttpResponse<String> response = getString("/api/resources/" + id + "/content");
        assertEquals(404, response.statusCode());
        assertEquals("RESOURCE_NOT_FOUND", mapper.readTree(response.body()).get("code").asText());
    }

    @Test
    void missingBytesRefuseDownloadInsteadOfEmptyFile() throws Exception {
        byte[] content = "缺失字节：拒绝下载并告警，绝不返回空文件".getBytes(StandardCharsets.UTF_8);
        String digest = sha256Hex(content);
        JsonNode uploaded = upload("字节缺失.bin", "application/octet-stream", content);
        UUID id = UUID.fromString(uploaded.get("id").asText());
        Files.delete(Path.of("target/task5-test-data-root", "sha256",
                digest.substring(0, 2), digest.substring(2, 4), digest));

        HttpResponse<byte[]> response = download(id, null);
        assertEquals(500, response.statusCode(), "缺失字节拒绝下载（08-验收规范 §4 故障矩阵）");
        JsonNode error = mapper.readTree(new String(response.body(), StandardCharsets.UTF_8));
        assertEquals("INTERNAL_ERROR", error.get("code").asText());
        assertNotEquals(200, response.statusCode(), "绝不以 200 返回空文件");
        Integer readyRows = jdbc.queryForObject(
                "SELECT count(*) FROM cangshu_m1.content WHERE status = 'READY'", Integer.class);
        assertEquals(1, readyRows, "拒绝下载不改库内状态（对账属任务 28）");
    }

    @Test
    void deduplicatedResourcesShareDownloadableContent() throws Exception {
        byte[] content = "一条物理内容，两条逻辑引用，各自可下载".getBytes(StandardCharsets.UTF_8);
        String digest = sha256Hex(content);
        JsonNode first = upload("第一份.bin", "application/octet-stream", content);
        JsonNode second = upload("第二份.bin", "application/octet-stream", content);
        UUID firstId = UUID.fromString(first.get("id").asText());
        UUID secondId = UUID.fromString(second.get("id").asText());
        assertNotEquals(firstId, secondId);
        assertEquals(first.get("contentId").asText(), second.get("contentId").asText(), "共享同一内容身份");

        for (UUID id : new UUID[] {firstId, secondId}) {
            HttpResponse<byte[]> response = download(id, null);
            assertEquals(200, response.statusCode());
            assertEquals(digest, sha256Hex(response.body()), "每条引用下载字节 SHA-256 恒等");
        }
    }

    @Test
    void largerPayloadStreamsThroughWithIdenticalHash() throws Exception {
        // 套件内流式回归：32MB 载荷经 multipart 上传与下载，哈希恒等（ACC-G2 大阶梯随 e2e 证据包）
        byte[] content = new byte[32 * 1024 * 1024];
        new java.util.Random(20260919L).nextBytes(content);
        String digest = sha256Hex(content);
        JsonNode uploaded = upload("流式回归-32MB.bin", "application/octet-stream", content);
        UUID id = UUID.fromString(uploaded.get("id").asText());
        assertEquals(digest, uploaded.get("hash").get("digest").asText(), "上传摘要＝源文件哈希");

        HttpResponse<byte[]> response = download(id, null);
        assertEquals(200, response.statusCode());
        assertEquals(content.length, response.body().length, "下载字节数恒等");
        assertEquals(digest, sha256Hex(response.body()), "下载哈希恒等（32MB 流式）");
    }
}
