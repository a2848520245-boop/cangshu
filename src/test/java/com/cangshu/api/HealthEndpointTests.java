package com.cangshu.api;

import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.test.web.servlet.MockMvc;

/** 健康检查（Actuator）与最小接口 /api/health 的默认配置行为。 */
@SpringBootTest
@AutoConfigureMockMvc
class HealthEndpointTests {

    @Autowired
    private MockMvc mockMvc;

    @Test
    void actuatorHealthIsUp() throws Exception {
        this.mockMvc.perform(get("/actuator/health"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.status").value("UP"));
    }

    @Test
    void apiHealthReturnsDefaults() throws Exception {
        this.mockMvc.perform(get("/api/health"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.status").value("UP"))
                .andExpect(jsonPath("$.service").value("cangshu"))
                .andExpect(jsonPath("$.config.dataRoot").value(org.hamcrest.Matchers.endsWith("data-root")))
                .andExpect(jsonPath("$.config.uploadMaxSizeBytes").value(2147483648L))
                .andExpect(jsonPath("$.config.trashRetention").value("PT168H"))
                .andExpect(jsonPath("$.config.migrationDir").value(org.hamcrest.Matchers.endsWith("migration")))
                .andExpect(jsonPath("$.config.migrationLockKey").value(20260918))
                .andExpect(jsonPath("$.config.writerLockKey").value(20260919));
    }
}
