package com.cangshu.api;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.cangshu.storage.Digestor;
import com.cangshu.storage.SegmentLockManager;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.io.ByteArrayOutputStream;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.HexFormat;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.atomic.AtomicReference;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.context.TestConfiguration;
import org.springframework.boot.test.web.server.LocalServerPort;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Primary;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.util.FileSystemUtils;

/**
 * 任务 3 真实 HTTP 集成测试（ACC-HTTP 任务级切片）：独立 Tomcat（随机端口）经 TCP 请求
 * {@code POST /api/resources}，覆盖首传／重复上传（201、contentId、deduplicated）、
 * 400／409（SIZE_MISMATCH／BYTE_MISMATCH／TARGET_PATH_EXISTS）／503（生产 30 秒超时实测）。
 *
 * <p>哈希冲突与锁超时由测试构建专用注入驱动：{@link FakeDigestorConfig}（仅测试装配，正式制品
 * 不含假摘要夹具，无运行期开关）。前提：本机 PostgreSQL 17 已运行且 {@code cangshu_test} 库已按
 * {@code db/migration/V1__init.sql} 初始化（08-验收规范 §2：注入经真实 TCP 完成，不进程内调用服务层）。
 */
@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.RANDOM_PORT, properties = {
        "spring.datasource.url=jdbc:postgresql://127.0.0.1:5432/cangshu_test?currentSchema=cangshu_m1",
        "spring.datasource.username=postgres",
        "spring.datasource.password=postgres",
        "cangshu.data-root=target/task3-test-data-root"
})
class UploadFlowIntegrationTests {

    /** 测试构建专用注入：固定摘要器接缝（null＝透传真实 SHA-256）。 */
    static final AtomicReference<String> FIXED_DIGEST = new AtomicReference<>(null);

    @TestConfiguration
    static class FakeDigestorConfig {
        @Bean
        @Primary
        Digestor fixedDigestor() {
            return new Digestor() {
                @Override
                public String canonicalAlgorithm() {
                    return "SHA-256";
                }

                @Override
                public MessageDigest create() {
                    String fixed = FIXED_DIGEST.get();
                    if (fixed == null) {
                        return new Sha256Real().create();
                    }
                    return new FixedMessageDigest(HexFormat.of().parseHex(fixed));
                }
            };
        }
    }

    /** 真实 SHA-256（生产 Bean 被 @Primary 覆盖，这里手工透传）。 */
    static class Sha256Real implements Digestor {
        @Override
        public String canonicalAlgorithm() {
            return "SHA-256";
        }

        @Override
        public MessageDigest create() {
            try {
                return MessageDigest.getInstance("SHA-256");
            } catch (Exception e) {
                throw new IllegalStateException(e);
            }
        }
    }

    /** 假摘要器：忽略全部输入，digest() 恒返回构造时给定的字节。 */
    static final class FixedMessageDigest extends MessageDigest {
        private final byte[] fixed;

        FixedMessageDigest(byte[] fixed) {
            super("FIXED");
            this.fixed = fixed.clone();
        }

        @Override
        protected void engineUpdate(byte input) {
        }

        @Override
        protected void engineUpdate(byte[] input, int offset, int length) {
        }

        @Override
        protected byte[] engineDigest() {
            return fixed.clone();
        }

        @Override
        protected void engineReset() {
        }
    }

    @LocalServerPort
    int port;

    @Autowired
    JdbcTemplate jdbc;

    @Autowired
    SegmentLockManager locks;

    final HttpClient http = HttpClient.newHttpClient();
    final ObjectMapper mapper = new ObjectMapper();

    @BeforeEach
    void cleanState() throws Exception {
        jdbc.update("TRUNCATE cangshu_m1.resource, cangshu_m1.location, cangshu_m1.content_conflict, cangshu_m1.content");
        FileSystemUtils.deleteRecursively(java.nio.file.Path.of("target/task3-test-data-root"));
        FIXED_DIGEST.set(null);
    }

    @AfterEach
    void resetFixture() {
        FIXED_DIGEST.set(null);
    }

    // ────────────────────────── HTTP 辅助（真实 TCP multipart） ──────────────────────────

    private String baseUrl() {
        return "http://127.0.0.1:" + port;
    }

    /** 标准 multipart 请求体：字段 file（单文件）。 */
    static byte[] multipartBody(String boundary, String fieldName, String filename, String contentType, byte[] content) {
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        out.writeBytes(("--" + boundary + "\r\nContent-Disposition: form-data; name=\"" + fieldName + "\"; filename=\""
                + filename + "\"\r\nContent-Type: " + contentType + "\r\n\r\n").getBytes(StandardCharsets.UTF_8));
        out.writeBytes(content);
        out.writeBytes(("\r\n--" + boundary + "--\r\n").getBytes(StandardCharsets.UTF_8));
        return out.toByteArray();
    }

    private HttpResponse<String> postUpload(byte[] body, String boundary) throws Exception {
        HttpRequest request = HttpRequest.newBuilder(URI.create(baseUrl() + "/api/resources"))
                .header("Content-Type", "multipart/form-data; boundary=" + boundary)
                .POST(HttpRequest.BodyPublishers.ofByteArray(body))
                .build();
        return http.send(request, HttpResponse.BodyHandlers.ofString());
    }

    private HttpResponse<String> upload(String filename, String contentType, byte[] content) throws Exception {
        String boundary = "cangshu-test-" + UUID.randomUUID();
        return postUpload(multipartBody(boundary, "file", filename, contentType, content), boundary);
    }

    private static String sha256Hex(byte[] content) throws Exception {
        MessageDigest digest = MessageDigest.getInstance("SHA-256");
        return HexFormat.of().formatHex(digest.digest(content));
    }

    private static void assertContractError(HttpResponse<String> response, int expectedStatus,
            String expectedCode, String expectedReason) throws Exception {
        assertEquals(expectedStatus, response.statusCode());
        JsonNode body = new ObjectMapper().readTree(response.body());
        assertEquals(expectedCode, body.get("code").asText());
        if (expectedReason == null) {
            assertTrue(!body.has("reason") || body.get("reason").isNull(), "非冲突错误体不携带 reason");
        } else {
            assertEquals(expectedReason, body.get("reason").asText(), "冲突响应 reason 必填（I1）");
        }
    }

    // ────────────────────────── 用例 ──────────────────────────

    @Test
    void firstUploadThenDuplicateCreatesTwoResourcesOneContent() throws Exception {
        byte[] content = "ACC-G3：同一文件上传两次，两条资源、一份内容".getBytes(StandardCharsets.UTF_8);
        String digest = sha256Hex(content);

        HttpResponse<String> first = upload("首次上传.bin", "application/octet-stream", content);
        assertEquals(201, first.statusCode());
        JsonNode body = mapper.readTree(first.body());
        UUID firstResourceId = UUID.fromString(body.get("id").asText());
        UUID contentId = UUID.fromString(body.get("contentId").asText());
        assertEquals(7, firstResourceId.version(), "资源 ID 为 UUIDv7");
        assertEquals("首次上传.bin", body.get("name").asText());
        assertEquals(content.length, body.get("sizeBytes").asLong());
        assertEquals("sha256", body.get("hash").get("algorithm").asText(), "对外显示值 sha256");
        assertEquals(digest, body.get("hash").get("digest").asText(), "摘要为小写 64 位十六进制");
        assertEquals("READY", body.get("status").asText());
        assertTrue(body.get("createdAt").asText().endsWith("Z"), "ISO-8601 UTC");
        assertTrue(body.get("deduplicated").isBoolean() && !body.get("deduplicated").asBoolean());
        assertEquals(0, body.get("tags").size());

        HttpResponse<String> second = upload("重复上传.bin", "application/octet-stream", content);
        assertEquals(201, second.statusCode());
        JsonNode secondBody = mapper.readTree(second.body());
        assertTrue(secondBody.get("deduplicated").asBoolean(), "命中已有内容 → deduplicated=true");
        assertEquals(contentId, UUID.fromString(secondBody.get("contentId").asText()), "contentId 指向既有内容");
        assertNotEquals(firstResourceId, UUID.fromString(secondBody.get("id").asText()), "默认新建一条资源引用");

        // 数据库快照：逻辑资源两条、物理内容一份
        Integer resourceCount = jdbc.queryForObject("SELECT count(*) FROM cangshu_m1.resource", Integer.class);
        Integer contentCount = jdbc.queryForObject("SELECT count(*) FROM cangshu_m1.content", Integer.class);
        assertEquals(2, resourceCount);
        assertEquals(1, contentCount);
        Map<String, Object> contentRow = jdbc.queryForMap(
                "SELECT hash_algorithm, digest, size_bytes, status FROM cangshu_m1.content");
        assertEquals("SHA-256", contentRow.get("hash_algorithm"), "库内规范值");
        assertEquals(digest, contentRow.get("digest"));
        assertEquals(content.length, ((Number) contentRow.get("size_bytes")).longValue());
        assertEquals("READY", contentRow.get("status"));
        Map<String, Object> location = jdbc.queryForMap(
                "SELECT storage_backend, storage_key FROM cangshu_m1.location");
        assertEquals("filesystem", location.get("storage_backend"));
        assertEquals("sha256/" + digest.substring(0, 2) + "/" + digest.substring(2, 4) + "/" + digest,
                location.get("storage_key"), "相对存储键＝sha256/ab/cd/<digest>");
    }

    @Test
    void missingFilePartReturns400InvalidArgument() throws Exception {
        String boundary = "cangshu-test-missing";
        byte[] body = ("--" + boundary + "\r\nContent-Disposition: form-data; name=\"notfile\"\r\n\r\nx\r\n--"
                + boundary + "--\r\n").getBytes(StandardCharsets.UTF_8);
        assertContractError(postUpload(body, boundary), 400, "INVALID_ARGUMENT", null);
        Integer contentCount = jdbc.queryForObject("SELECT count(*) FROM cangshu_m1.content", Integer.class);
        assertEquals(0, contentCount, "失败路径不产生可见资源");
    }

    @Test
    void blankFilenameReturns400InvalidArgument() throws Exception {
        String boundary = "cangshu-test-blankname";
        HttpResponse<String> response = postUpload(
                multipartBody(boundary, "file", "", "text/plain", "no-name".getBytes(StandardCharsets.UTF_8)),
                boundary);
        assertTrue(response.statusCode() == 400, "缺原始文件名 → 400，实际 " + response.statusCode());
        assertEquals("INVALID_ARGUMENT", mapper.readTree(response.body()).get("code").asText());
    }

    @Test
    void duplicateUploadAfterRowLossReconcilesIndexRows() throws Exception {
        // 分支 F 正例：内容地址已有字节而库内无行 → 字节相同 → 幂等补齐索引行（reused=true）
        byte[] content = "F 分支：字节已在、行已丢".getBytes(StandardCharsets.UTF_8);
        HttpResponse<String> first = upload("丢失行.bin", "application/octet-stream", content);
        assertEquals(201, first.statusCode());
        jdbc.update("DELETE FROM cangshu_m1.resource");
        jdbc.update("DELETE FROM cangshu_m1.location");
        jdbc.update("DELETE FROM cangshu_m1.content");

        HttpResponse<String> again = upload("补齐行.bin", "application/octet-stream", content);
        assertEquals(201, again.statusCode());
        JsonNode body = mapper.readTree(again.body());
        assertTrue(body.get("deduplicated").asBoolean(), "字节相同 → 幂等补齐并复用");
        Integer contentCount = jdbc.queryForObject("SELECT count(*) FROM cangshu_m1.content", Integer.class);
        assertEquals(1, contentCount, "补齐后内容行恢复");
        String digest = sha256Hex(content);
        byte[] blob = java.nio.file.Files.readAllBytes(java.nio.file.Path.of("target/task3-test-data-root",
                "sha256", digest.substring(0, 2), digest.substring(2, 4), digest));
        assertEquals(HexFormat.of().formatHex(sha256Raw(content)), HexFormat.of().formatHex(sha256Raw(blob)),
                "补齐不覆盖既有字节");
    }

    @Test
    void targetPathExistsWithDifferentBytesReturns409AndAudit() throws Exception {
        byte[] first = "TARGET-PATH-EXISTS 既有字节".getBytes(StandardCharsets.UTF_8);
        HttpResponse<String> uploaded = upload("既有.bin", "application/octet-stream", first);
        assertEquals(201, uploaded.statusCode());
        String digest = sha256Hex(first);
        jdbc.update("DELETE FROM cangshu_m1.resource");
        jdbc.update("DELETE FROM cangshu_m1.location");
        jdbc.update("DELETE FROM cangshu_m1.content");

        // 注入：同摘要假摘要器 ＋ 同大小不同字节 → F 冲突路径
        byte[] incoming = "TARGET-PATH-EXISTS 来者字节".getBytes(StandardCharsets.UTF_8);
        assertEquals(first.length, incoming.length, "前置：同大小");
        FIXED_DIGEST.set(digest);
        HttpResponse<String> response = upload("来者.bin", "application/octet-stream", incoming);
        assertContractError(response, 409, "CONTENT_CONFLICT", "TARGET_PATH_EXISTS");

        Integer contentCount = jdbc.queryForObject("SELECT count(*) FROM cangshu_m1.content", Integer.class);
        assertEquals(0, contentCount, "冲突不写内容行");
        Integer audits = jdbc.queryForObject(
                "SELECT count(*) FROM cangshu_m1.content_conflict WHERE reason = 'TARGET_PATH_EXISTS' AND incoming_size_bytes = ?",
                Integer.class, incoming.length);
        assertEquals(1, audits, "冲突审计留痕（独立短事务）");
        assertEquals(HexFormat.of().formatHex(sha256Raw(first)), storageKeyDigestOnDisk(digest),
                "原字节不动：目标键字节与首传一致");
    }

    @Test
    void sizeMismatchReturns409WithoutReusingBytes() throws Exception {
        byte[] first = "SIZE-MISMATCH 既有内容（较长）".getBytes(StandardCharsets.UTF_8);
        upload("既有.bin", "application/octet-stream", first);
        String digest = sha256Hex(first);
        String before = storageKeyDigestOnDisk(digest);

        byte[] incoming = "更短".getBytes(StandardCharsets.UTF_8);
        assertNotEquals(first.length, incoming.length);
        FIXED_DIGEST.set(digest);
        HttpResponse<String> response = upload("来者.bin", "application/octet-stream", incoming);
        assertContractError(response, 409, "CONTENT_CONFLICT", "SIZE_MISMATCH");
        assertEquals(before, storageKeyDigestOnDisk(digest), "原行原字节不动");
        Integer resourceCount = jdbc.queryForObject("SELECT count(*) FROM cangshu_m1.resource", Integer.class);
        assertEquals(1, resourceCount, "冲突不新增资源行");
        Integer audits = jdbc.queryForObject(
                "SELECT count(*) FROM cangshu_m1.content_conflict WHERE reason = 'SIZE_MISMATCH'", Integer.class);
        assertEquals(1, audits, "冲突审计留痕");
    }

    @Test
    void byteMismatchWithSameSizeReturns409() throws Exception {
        byte[] first = "BYTE-MISMATCH 同大小不同字节 A".getBytes(StandardCharsets.UTF_8);
        upload("既有.bin", "application/octet-stream", first);
        String digest = sha256Hex(first);
        String before = storageKeyDigestOnDisk(digest);

        byte[] incoming = "BYTE-MISMATCH 同大小不同字节 B".getBytes(StandardCharsets.UTF_8);
        assertEquals(first.length, incoming.length, "前置：同大小");
        FIXED_DIGEST.set(digest);
        HttpResponse<String> response = upload("来者.bin", "application/octet-stream", incoming);
        assertContractError(response, 409, "CONTENT_CONFLICT", "BYTE_MISMATCH");
        assertEquals(before, storageKeyDigestOnDisk(digest), "原行原字节不动");
        Integer audits = jdbc.queryForObject(
                "SELECT count(*) FROM cangshu_m1.content_conflict WHERE reason = 'BYTE_MISMATCH'", Integer.class);
        assertEquals(1, audits, "冲突审计留痕");
    }

    @Test
    void lockTimeoutReturns503WithProductionThirtySecondTimeout() throws Exception {
        byte[] content = "等锁 30 秒 → 503 SERVICE_BUSY（生产实际超时值实测）".getBytes(StandardCharsets.UTF_8);
        String digest = sha256Hex(content);
        long start = System.nanoTime();
        try (SegmentLockManager.Handle held = locks.acquire("SHA-256", digest)) {
            HttpResponse<String> response = upload("被锁.bin", "application/octet-stream", content);
            long elapsedMillis = (System.nanoTime() - start) / 1_000_000;
            assertContractError(response, 503, "SERVICE_BUSY", null);
            assertTrue(elapsedMillis >= 29_000, "必须用生产实际超时值（30 秒）实测，实际 " + elapsedMillis + "ms");
        }
        Integer contentCount = jdbc.queryForObject("SELECT count(*) FROM cangshu_m1.content", Integer.class);
        assertEquals(0, contentCount, "503 路径不产生内容行");
    }

    // ────────────────────────── 断言辅助 ──────────────────────────

    private static byte[] sha256Raw(byte[] content) throws Exception {
        return MessageDigest.getInstance("SHA-256").digest(content);
    }

    /** 读内容地址上的既有字节并返回其 SHA-256（核对「原字节不动」）。 */
    private String storageKeyDigestOnDisk(String digest) throws Exception {
        byte[] blob = java.nio.file.Files.readAllBytes(java.nio.file.Path.of("target/task3-test-data-root",
                "sha256", digest.substring(0, 2), digest.substring(2, 4), digest));
        return HexFormat.of().formatHex(sha256Raw(blob));
    }
}
