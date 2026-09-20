package com.cangshu.api;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.cangshu.catalog.CatalogException;
import jakarta.servlet.http.HttpServletRequest;
import java.nio.charset.StandardCharsets;
import java.util.UUID;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.springframework.http.HttpMethod;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.MvcResult;
import org.springframework.test.web.servlet.setup.MockMvcBuilders;
import org.springframework.web.HttpRequestMethodNotSupportedException;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.web.multipart.MaxUploadSizeExceededException;
import org.springframework.web.multipart.MultipartException;
import org.springframework.web.multipart.support.MissingServletRequestPartException;
import org.springframework.web.servlet.resource.NoResourceFoundException;

/**
 * 契约错误码映射单元测试（api，05-接口契约 §2 ＋ ADR DEC-I10）。
 *
 * <p>补的是「每个 {@code @ExceptionHandler} 分支都有断言」：错误体扁平形状、非冲突响应不带
 * {@code reason}、冲突响应必带 {@code reason}、HTTP 状态与 {@code code} 对齐，
 * 以及未预期异常一律 {@code INTERNAL_ERROR} 且<b>不泄露内部细节</b>。
 * 用 standalone MockMvc，不依赖数据库与 Spring 容器。
 */
class ApiExceptionHandlerTests {

    private MockMvc mockMvc;

    /** 只负责抛出各类异常，用于驱动 advice。 */
    @RestController
    static class ThrowingController {

        @GetMapping("/catalog/{code}")
        String catalog(@PathVariable("code") String code) {
            switch (code) {
                case "invalid":
                    throw CatalogException.invalidArgument("分页参数非法");
                case "not-found":
                    throw new CatalogException(CatalogException.Code.RESOURCE_NOT_FOUND, "资源不存在", null);
                case "conflict":
                    throw CatalogException.conflict("SIZE_MISMATCH", "内容校验冲突：同摘要内容大小不一致");
                case "too-large":
                    throw CatalogException.payloadTooLarge("单文件超过上限");
                case "hash":
                    throw CatalogException.hashMismatch("内容损坏");
                case "busy":
                    throw CatalogException.serviceBusy("服务正忙，请稍后重试");
                default:
                    throw CatalogException.internalError("服务内部错误，请稍后重试");
            }
        }

        @GetMapping("/missing-part")
        String missingPart() throws MissingServletRequestPartException {
            throw new MissingServletRequestPartException("file");
        }

        @GetMapping("/max-upload")
        String maxUpload() {
            throw new MaxUploadSizeExceededException(1024L);
        }

        @GetMapping("/multipart")
        String multipart() {
            throw new MultipartException("multipart 解析失败");
        }

        @GetMapping("/no-resource")
        String noResource() throws NoResourceFoundException {
            throw new NoResourceFoundException(HttpMethod.GET, "/static/not-there.txt");
        }

        @GetMapping("/method-not-supported")
        String methodNotSupported() throws HttpRequestMethodNotSupportedException {
            throw new HttpRequestMethodNotSupportedException("PUT");
        }

        @GetMapping("/uuid/{id}")
        String uuid(@PathVariable("id") UUID id) {
            return id.toString();
        }

        @GetMapping("/unexpected")
        String unexpected(HttpServletRequest request) {
            throw new IllegalStateException("内部细节：连接串 jdbc:postgresql://user:secret@host/db");
        }
    }

    @BeforeEach
    void setUp() {
        mockMvc = MockMvcBuilders.standaloneSetup(new ThrowingController())
                .setControllerAdvice(new ApiExceptionHandler())
                .build();
    }

    private MvcResult call(String path) throws Exception {
        return mockMvc.perform(org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get(path))
                .andReturn();
    }

    private static String body(MvcResult result) {
        try {
            return result.getResponse().getContentAsString(StandardCharsets.UTF_8);
        } catch (Exception e) {
            throw new IllegalStateException(e);
        }
    }

    private static void assertErrorBody(MvcResult result, int expectedStatus, String expectedCode,
            String expectedReason) {
        assertEquals(expectedStatus, result.getResponse().getStatus());
        String json = body(result);
        assertTrue(json.contains("\"code\":\"" + expectedCode + "\""),
                "错误体 code 应为 " + expectedCode + "，实际 " + json);
        if (expectedReason == null) {
            assertFalse(json.contains("\"reason\""), "非冲突错误体不携带 reason：" + json);
        } else {
            assertTrue(json.contains("\"reason\":\"" + expectedReason + "\""),
                    "冲突响应 reason 必填（I1），实际 " + json);
        }
    }

    // ────────────────────────── CatalogException 全码映射 ──────────────────────────

    @Test
    @DisplayName("INVALID_ARGUMENT → 400，错误体为扁平对象且无 reason")
    void invalidArgumentMapsTo400() throws Exception {
        assertErrorBody(call("/catalog/invalid"), 400, "INVALID_ARGUMENT", null);
    }

    @Test
    @DisplayName("RESOURCE_NOT_FOUND → 404，无 reason")
    void notFoundMapsTo404() throws Exception {
        assertErrorBody(call("/catalog/not-found"), 404, "RESOURCE_NOT_FOUND", null);
    }

    @Test
    @DisplayName("CONTENT_CONFLICT → 409 且 reason 必填")
    void conflictMapsTo409WithReason() throws Exception {
        assertErrorBody(call("/catalog/conflict"), 409, "CONTENT_CONFLICT", "SIZE_MISMATCH");
    }

    @Test
    @DisplayName("PAYLOAD_TOO_LARGE → 413，无 reason")
    void payloadTooLargeMapsTo413() throws Exception {
        assertErrorBody(call("/catalog/too-large"), 413, "PAYLOAD_TOO_LARGE", null);
    }

    @Test
    @DisplayName("HASH_MISMATCH → 422，无 reason")
    void hashMismatchMapsTo422() throws Exception {
        assertErrorBody(call("/catalog/hash"), 422, "HASH_MISMATCH", null);
    }

    @Test
    @DisplayName("SERVICE_BUSY → 503，无 reason（明确可重试）")
    void serviceBusyMapsTo503() throws Exception {
        assertErrorBody(call("/catalog/busy"), 503, "SERVICE_BUSY", null);
    }

    @Test
    @DisplayName("INTERNAL_ERROR → 500，无 reason")
    void internalErrorMapsTo500() throws Exception {
        assertErrorBody(call("/catalog/internal"), 500, "INTERNAL_ERROR", null);
    }

    // ────────────────────────── 框架异常映射 ──────────────────────────

    @Test
    @DisplayName("缺 multipart 必填字段 → 400 INVALID_ARGUMENT")
    void missingPartMapsTo400() throws Exception {
        assertErrorBody(call("/missing-part"), 400, "INVALID_ARGUMENT", null);
    }

    @Test
    @DisplayName("路径参数类型不匹配（非 UUID 资源 ID）→ 400 INVALID_ARGUMENT")
    void typeMismatchMapsTo400() throws Exception {
        assertErrorBody(call("/uuid/not-a-uuid"), 400, "INVALID_ARGUMENT", null);
    }

    @Test
    @DisplayName("合法 UUID 路径参数不被误判（负对照）")
    void validUuidPathIsServed() throws Exception {
        MvcResult result = call("/uuid/" + UUID.randomUUID());
        assertEquals(200, result.getResponse().getStatus(), "正常请求不得被错误处理分支截走");
    }

    @Test
    @DisplayName("HTTP 层超限（MaxUploadSizeExceededException）→ 413 PAYLOAD_TOO_LARGE")
    void maxUploadSizeMapsTo413() throws Exception {
        assertErrorBody(call("/max-upload"), 413, "PAYLOAD_TOO_LARGE", null);
    }

    @Test
    @DisplayName("multipart 解析失败 → 400 INVALID_ARGUMENT")
    void multipartFailureMapsTo400() throws Exception {
        assertErrorBody(call("/multipart"), 400, "INVALID_ARGUMENT", null);
    }

    @Test
    @DisplayName("静态资源不存在 → 404 RESOURCE_NOT_FOUND")
    void noResourceMapsTo404() throws Exception {
        assertErrorBody(call("/no-resource"), 404, "RESOURCE_NOT_FOUND", null);
    }

    @Test
    @DisplayName("不支持的请求方法 → 400（契约未定义 405，不新增 405 语义：DEC-I10）")
    void methodNotSupportedMapsTo400WithoutIntroducing405() throws Exception {
        MvcResult result = call("/method-not-supported");
        assertErrorBody(result, 400, "INVALID_ARGUMENT", null);
        assertFalse(result.getResponse().getStatus() == 405, "DEC-I10 明确不新增 405 语义");
    }

    // ────────────────────────── 未预期异常 ──────────────────────────

    @Test
    @DisplayName("未预期异常 → 500 INTERNAL_ERROR，且不把内部细节写进响应体")
    void unexpectedExceptionDoesNotLeakInternalDetails() throws Exception {
        MvcResult result = call("/unexpected");
        assertEquals(500, result.getResponse().getStatus());
        String json = body(result);
        assertTrue(json.contains("\"code\":\"INTERNAL_ERROR\""), json);
        assertFalse(json.contains("secret"), "响应体不得泄露连接串等内部细节：" + json);
        assertFalse(json.contains("IllegalStateException"), "响应体不得泄露异常类型：" + json);
    }
}
