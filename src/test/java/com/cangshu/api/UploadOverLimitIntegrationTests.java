package com.cangshu.api;

import static org.junit.jupiter.api.Assertions.assertEquals;

import com.fasterxml.jackson.databind.ObjectMapper;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.util.UUID;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.web.server.LocalServerPort;
import org.springframework.jdbc.core.JdbcTemplate;

/**
 * 超上限负例（08-验收规范 §5：上传超限必须拒收并返回 413）。
 * 独立上下文把业务上限压到 16KB；HTTP 层与业务上限同源（07-运行手册 §1）。
 */
@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.RANDOM_PORT, properties = {
        "spring.datasource.url=jdbc:postgresql://127.0.0.1:5432/cangshu_test?currentSchema=cangshu_m1",
        "spring.datasource.username=postgres",
        "spring.datasource.password=postgres",
        "cangshu.data-root=target/task3-test-over-limit",
        "cangshu.upload.max-size=16KB"
})
class UploadOverLimitIntegrationTests {

    @LocalServerPort
    int port;

    @Autowired
    JdbcTemplate jdbc;

    final HttpClient http = HttpClient.newHttpClient();
    final ObjectMapper mapper = new ObjectMapper();

    @BeforeEach
    void cleanState() {
        jdbc.update("TRUNCATE cangshu_m1.resource, cangshu_m1.location, cangshu_m1.content_conflict, cangshu_m1.content");
    }

    @Test
    void overLimitUploadReturns413PayloadTooLarge() throws Exception {
        byte[] content = new byte[20 * 1024];
        String boundary = "cangshu-test-" + UUID.randomUUID();
        byte[] body = UploadFlowIntegrationTests.multipartBody(boundary, "file", "超大.bin",
                "application/octet-stream", content);
        HttpRequest request = HttpRequest.newBuilder(URI.create("http://127.0.0.1:" + port + "/api/resources"))
                .header("Content-Type", "multipart/form-data; boundary=" + boundary)
                .POST(HttpRequest.BodyPublishers.ofByteArray(body))
                .build();
        HttpResponse<String> response = http.send(request, HttpResponse.BodyHandlers.ofString());
        assertEquals(413, response.statusCode(), "超上限必须拒收并返回 413");
        assertEquals("PAYLOAD_TOO_LARGE", mapper.readTree(response.body()).get("code").asText());
        Integer contentCount = jdbc.queryForObject("SELECT count(*) FROM cangshu_m1.content", Integer.class);
        assertEquals(0, contentCount, "超限路径不产生内容行");
    }

    @Test
    void withinLimitUploadSucceedsAtConfiguredBoundary() throws Exception {
        // 16KB 以内（留出 multipart 开销余量在请求上限中）：8KB 应正常入库
        byte[] content = new byte[8 * 1024];
        String boundary = "cangshu-test-" + UUID.randomUUID();
        byte[] body = UploadFlowIntegrationTests.multipartBody(boundary, "file", "限内.bin",
                "application/octet-stream", content);
        HttpRequest request = HttpRequest.newBuilder(URI.create("http://127.0.0.1:" + port + "/api/resources"))
                .header("Content-Type", "multipart/form-data; boundary=" + boundary)
                .POST(HttpRequest.BodyPublishers.ofByteArray(body))
                .build();
        HttpResponse<String> response = http.send(request, HttpResponse.BodyHandlers.ofString());
        assertEquals(201, response.statusCode());
        assertEquals(8192L, mapper.readTree(response.body()).get("sizeBytes").asLong());
    }
}
