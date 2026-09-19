package com.cangshu.api;

import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import org.hamcrest.Matchers;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.test.web.servlet.MockMvc;

/** 配置注入可复现：同一端点在配置被覆盖后，生效值随配置变化。 */
@SpringBootTest(properties = {
        "cangshu.data-root=target/test-data-root",
        "cangshu.upload.max-size=1GB",
        "cangshu.trash.retention=0",
        "cangshu.migration.dir=target/test-migration"
})
@AutoConfigureMockMvc
class ConfigInjectionTests {

    @Autowired
    private MockMvc mockMvc;

    @Test
    void apiHealthReflectsOverriddenConfig() throws Exception {
        this.mockMvc.perform(get("/api/health"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.config.dataRoot").value(Matchers.containsString("test-data-root")))
                .andExpect(jsonPath("$.config.uploadMaxSizeBytes").value(1073741824L))
                .andExpect(jsonPath("$.config.trashRetention").value("PT0S"))
                .andExpect(jsonPath("$.config.migrationDir").value(Matchers.containsString("test-migration")));
    }

    @Test
    void protocolLockKeysAreImmutable() throws Exception {
        this.mockMvc.perform(get("/api/health"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.config.migrationLockKey").value(20260918))
                .andExpect(jsonPath("$.config.writerLockKey").value(20260919));
    }
}
