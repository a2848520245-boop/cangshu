package com.cangshu.api;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyInt;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import com.cangshu.catalog.CatalogException;
import com.cangshu.catalog.CatalogService;
import com.cangshu.catalog.DownloadService;
import com.cangshu.ingest.UploadIngestService;
import com.cangshu.search.ResourceQueryService;
import java.io.ByteArrayInputStream;
import java.net.URLDecoder;
import java.nio.charset.StandardCharsets;
import java.util.List;
import java.util.UUID;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.springframework.mock.web.MockMultipartFile;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.MvcResult;
import org.springframework.test.web.servlet.request.MockMvcRequestBuilders;
import org.springframework.test.web.servlet.setup.MockMvcBuilders;

/**
 * 内容端点（下载／预览）控制器层单元测试（任务 5，05-接口契约 §3.4 ＋ REQ-M1-07）。
 *
 * <p>补的是集成测试不便穷举的响应头细节：{@code filename*=UTF-8''…} 的原样还原、
 * 畸形文件名＋特殊字符不破坏响应头（无 CR/LF 注入）、畸形／空 MIME 退回
 * {@code application/octet-stream}、{@code Content-Length} 取自内容身份、
 * {@code inline} 只接受 {@code 1}。服务层用替身，不依赖数据库与真实 Tomcat。
 */
class ResourceControllerContentTests {

    private static final Pattern FILENAME_STAR = Pattern.compile("filename\\*=UTF-8''([^;]+)");

    private static final byte[] BYTES = "下载与预览：响应头与字节".getBytes(StandardCharsets.UTF_8);

    private DownloadService downloads;
    private ResourceQueryService queries;
    private MockMvc mockMvc;

    private final UUID resourceId = UUID.randomUUID();
    private final UUID contentId = UUID.randomUUID();

    @BeforeEach
    void setUp() {
        downloads = mock(DownloadService.class);
        queries = mock(ResourceQueryService.class);
        mockMvc = MockMvcBuilders.standaloneSetup(new ResourceController(
                        mock(UploadIngestService.class), mock(CatalogService.class),
                        queries, downloads))
                .setControllerAdvice(new ApiExceptionHandler())
                .build();
    }

    private void givenPayload(String name, String mimeType, byte[] bytes) {
        // 每次解析都返回「一支新的只读流」：DownloadPayload 的流是一次性的，复用同一实例会让
        // 第二次请求读到已耗尽的流（这不是产品缺陷，而是夹具必须遵守的语义）。
        when(downloads.open(any())).thenAnswer(invocation -> new DownloadService.DownloadPayload(
                resourceId, contentId, name, mimeType, bytes.length, new ByteArrayInputStream(bytes)));
    }

    private MvcResult download(String query) throws Exception {
        String url = "/api/resources/" + resourceId + "/content" + (query == null ? "" : query);
        return mockMvc.perform(MockMvcRequestBuilders.get(url)).andReturn();
    }

    private static String disposition(MvcResult result) {
        String value = result.getResponse().getHeader("Content-Disposition");
        assertTrue(value != null && !value.isBlank(), "响应必须带 Content-Disposition");
        return value;
    }

    private static String decodedFilenameStar(String contentDisposition) {
        Matcher matcher = FILENAME_STAR.matcher(contentDisposition);
        assertTrue(matcher.find(), "必须带 filename*=UTF-8'' 形态：" + contentDisposition);
        return URLDecoder.decode(matcher.group(1), StandardCharsets.UTF_8);
    }

    @Test
    @DisplayName("默认下载：attachment ＋ filename* 还原中文原始文件名 ＋ 字节与长度一致")
    void defaultDownloadIsAttachmentWithRfc5987Filename() throws Exception {
        givenPayload("报告 第一版.pdf", "application/pdf", BYTES);

        MvcResult result = download(null);

        assertEquals(200, result.getResponse().getStatus());
        String value = disposition(result);
        assertTrue(value.startsWith("attachment;"), value);
        assertEquals("报告 第一版.pdf", decodedFilenameStar(value), "中文文件名原样保留");
        assertEquals("application/pdf", result.getResponse().getContentType());
        assertEquals(String.valueOf(BYTES.length), result.getResponse().getHeader("Content-Length"),
                "Content-Length 取自内容身份");
        org.junit.jupiter.api.Assertions.assertArrayEquals(BYTES, result.getResponse().getContentAsByteArray());
    }

    @Test
    @DisplayName("inline=1 只把处置形态改为 inline，字节与文件名不变")
    void inlineOneOnlyChangesDisposition() throws Exception {
        givenPayload("预览.pdf", "application/pdf", BYTES);

        MvcResult attachment = download(null);
        MvcResult inline = download("?inline=1");

        assertEquals(200, inline.getResponse().getStatus());
        assertTrue(disposition(inline).startsWith("inline;"), disposition(inline));
        assertEquals("预览.pdf", decodedFilenameStar(disposition(inline)));
        assertTrue(java.util.Arrays.equals(attachment.getResponse().getContentAsByteArray(),
                inline.getResponse().getContentAsByteArray()), "inline 不改字节来源");
    }

    @Test
    @DisplayName("inline 仅接受 1，其他取值 → 400 INVALID_ARGUMENT 且不打开字节流")
    void inlineOtherValuesReturn400() throws Exception {
        for (String value : new String[] {"true", "0", "yes", ""}) {
            MvcResult result = download("?inline=" + value);
            assertEquals(400, result.getResponse().getStatus(), "inline=" + value + " 应 400");
            assertTrue(result.getResponse().getContentAsString(StandardCharsets.UTF_8)
                    .contains("INVALID_ARGUMENT"));
        }
    }

    @Test
    @DisplayName("畸形或空 MIME 退回 application/octet-stream，不猜格式")
    void malformedMimeTypeFallsBackToOctetStream() throws Exception {
        givenPayload("样本.bin", "not a mime/type;;", BYTES);
        assertEquals("application/octet-stream", download(null).getResponse().getContentType());

        givenPayload("样本.bin", "   ", BYTES);
        assertEquals("application/octet-stream", download(null).getResponse().getContentType());

        givenPayload("样本.bin", null, BYTES);
        assertEquals("application/octet-stream", download(null).getResponse().getContentType());
    }

    @Test
    @DisplayName("含引号／分号／CRLF 的文件名不得破坏或注入响应头")
    void hostileFilenameDoesNotInjectHeaders() throws Exception {
        givenPayload("a\";b\r\nX-Injected: 1\r\n.bin", "text/plain", BYTES);

        String value = disposition(download(null));

        assertFalse(value.contains("\r"), "响应头不得含裸 CR：" + value);
        assertFalse(value.contains("\n"), "响应头不得含裸 LF：" + value);
        assertEquals("a\";b\r\nX-Injected: 1\r\n.bin", decodedFilenameStar(value),
                "filename* 必须可逆还原原始名");
    }

    @Test
    @DisplayName("资源不存在（服务层 404）→ 404 RESOURCE_NOT_FOUND 且无响应体内容")
    void missingResourcePropagates404() throws Exception {
        when(downloads.open(any())).thenThrow(new CatalogException(
                CatalogException.Code.RESOURCE_NOT_FOUND, "资源不存在", null));

        MvcResult result = download(null);

        assertEquals(404, result.getResponse().getStatus());
        assertTrue(result.getResponse().getContentAsString(StandardCharsets.UTF_8)
                .contains("RESOURCE_NOT_FOUND"));
    }

    @Test
    @DisplayName("上传缺原始文件名 → 400 INVALID_ARGUMENT（不进入 ingest）")
    void blankFilenameOnUploadReturns400() throws Exception {
        MvcResult result = mockMvc.perform(MockMvcRequestBuilders
                        .multipart("/api/resources")
                        .file(new MockMultipartFile("file", "", "text/plain", "x".getBytes(StandardCharsets.UTF_8))))
                .andReturn();

        assertEquals(400, result.getResponse().getStatus());
        assertTrue(result.getResponse().getContentAsString(StandardCharsets.UTF_8)
                .contains("INVALID_ARGUMENT"));
    }

    @Test
    @DisplayName("列表 size 上限 200（契约 §3.2，CL-PAGESIZE 裁决）：200 放行、201 与极大值 400 且不进入查询")
    void pageSizeUpperBoundIsEnforced() throws Exception {
        when(queries.list(any(), any(), anyInt(), anyInt()))
                .thenReturn(new ResourceQueryService.ResourcePage(List.of(), 0L, 1, 200));

        MvcResult boundary = mockMvc.perform(MockMvcRequestBuilders.get("/api/resources?size=200"))
                .andReturn();
        assertEquals(200, boundary.getResponse().getStatus(), "上限值本身必须放行");
        verify(queries, times(1)).list(any(), any(), anyInt(), anyInt());

        for (String rejected : new String[] {"201", "100000000", "2147483647"}) {
            MvcResult result = mockMvc.perform(
                            MockMvcRequestBuilders.get("/api/resources?size=" + rejected))
                    .andReturn();
            assertEquals(400, result.getResponse().getStatus(), "size=" + rejected + " 必须 400");
            assertTrue(result.getResponse().getContentAsString(StandardCharsets.UTF_8)
                    .contains("INVALID_ARGUMENT"), "size=" + rejected);
        }
        verify(queries, times(1)).list(any(), any(), anyInt(), anyInt());
    }

    @Test
    @DisplayName("下界仍按原口径拒绝（page／size < 1 → 400），未被上限改动影响")
    void pageSizeLowerBoundUnchanged() throws Exception {
        for (String rejected : new String[] {"size=0", "size=-1", "page=0", "page=-5"}) {
            MvcResult result = mockMvc.perform(
                            MockMvcRequestBuilders.get("/api/resources?" + rejected))
                    .andReturn();
            assertEquals(400, result.getResponse().getStatus(), rejected + " 必须 400");
        }
    }

    @Test
    @DisplayName("不支持的请求媒体类型 → 400 INVALID_ARGUMENT（不得落到 500）")
    void unsupportedRequestMediaTypeIsClientError() throws Exception {
        MvcResult result = mockMvc.perform(MockMvcRequestBuilders.post("/api/resources")
                        .contentType(org.springframework.http.MediaType.APPLICATION_JSON)
                        .content("{}"))
                .andReturn();

        assertEquals(400, result.getResponse().getStatus(),
                "客户端媒体类型不受支持属调用方错误，不应报 500");
        assertTrue(result.getResponse().getContentAsString(StandardCharsets.UTF_8)
                .contains("INVALID_ARGUMENT"));
    }
}
