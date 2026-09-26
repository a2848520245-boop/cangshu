package com.cangshu.api;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

import com.cangshu.catalog.CatalogException;
import com.cangshu.catalog.CatalogService;
import com.cangshu.catalog.DownloadService;
import com.cangshu.catalog.TrashService;
import com.cangshu.ingest.UploadIngestService;
import com.cangshu.search.ResourceQueryService;
import java.io.ByteArrayInputStream;
import java.nio.charset.StandardCharsets;
import java.util.UUID;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.request.MockMvcRequestBuilders;
import org.springframework.test.web.servlet.setup.MockMvcBuilders;

/** The browser's download preflight uses HEAD on the existing GET content mapping. */
class ResourceHeadContractTests {
    private final UUID resourceId = UUID.randomUUID();
    private DownloadService downloads;
    private MockMvc mvc;

    @BeforeEach
    void setUp() {
        downloads = mock(DownloadService.class);
        mvc = MockMvcBuilders.standaloneSetup(new ResourceController(
                        mock(UploadIngestService.class), mock(CatalogService.class),
                        mock(ResourceQueryService.class), downloads, mock(TrashService.class)))
                .setControllerAdvice(new ApiExceptionHandler())
                .build();
    }

    @Test
    void existingContentAcceptsHeadWithDownloadHeaders() throws Exception {
        byte[] bytes = "hello".getBytes(StandardCharsets.UTF_8);
        when(downloads.open(resourceId)).thenReturn(new DownloadService.DownloadPayload(
                resourceId, UUID.randomUUID(), "sample.txt", "text/plain", bytes.length,
                new ByteArrayInputStream(bytes)));

        var response = mvc.perform(MockMvcRequestBuilders.head("/api/resources/{id}/content", resourceId))
                .andReturn().getResponse();

        assertEquals(200, response.getStatus());
        assertEquals(String.valueOf(bytes.length), response.getHeader("Content-Length"));
        assertTrue(response.getHeader("Content-Disposition").startsWith("attachment;"));
        // MockMvc buffers bytes from the GET handler for implicit HEAD; only a real
        // servlet/TCP exchange can establish whether bytes cross the wire.
    }

    @Test
    void missingContentReturnsErrorOnHead() throws Exception {
        when(downloads.open(any())).thenThrow(new CatalogException(
                CatalogException.Code.RESOURCE_NOT_FOUND, "资源不存在", null));

        var response = mvc.perform(MockMvcRequestBuilders.head("/api/resources/{id}/content", resourceId))
                .andReturn().getResponse();

        assertEquals(404, response.getStatus());
    }
}
