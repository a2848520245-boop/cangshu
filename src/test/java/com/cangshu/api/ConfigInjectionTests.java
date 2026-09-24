package com.cangshu.api;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import com.cangshu.IsolatedPostgresIntegrationTest;
import com.cangshu.storage.FileStore;
import java.nio.file.Path;
import org.hamcrest.Matchers;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.test.web.servlet.MockMvc;

/**
 * 配置注入可复现：同一端点在配置被覆盖后，生效值随配置变化。
 *
 * <p>任务 28 起上下文加载会连库跑启动对账（04 §8 步骤 3），故一并显式指向隔离 VM 内合成测试库。
 */
@SpringBootTest(properties = {
        "cangshu.data-root=target/test-data-root",
        "cangshu.upload.max-size=1GB",
        "cangshu.trash.retention=0",
        "cangshu.migration.dir=./db/migration",
        "spring.datasource.username=postgres",
        "spring.datasource.password=postgres"
})
@AutoConfigureMockMvc
class ConfigInjectionTests extends IsolatedPostgresIntegrationTest {

    @Autowired
    private MockMvc mockMvc;

    @Autowired
    private FileStore files;

    @Test
    void apiHealthReflectsOverriddenConfig() throws Exception {
        this.mockMvc.perform(get("/api/health"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.config.dataRoot").value(Matchers.containsString("test-data-root")))
                .andExpect(jsonPath("$.config.uploadMaxSizeBytes").value(1073741824L))
                .andExpect(jsonPath("$.config.trashRetention").value("PT0S"))
                .andExpect(jsonPath("$.config.migrationDir").value(Matchers.endsWith("migration")));
    }

    @Test
    void protocolLockKeysAreImmutable() throws Exception {
        this.mockMvc.perform(get("/api/health"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.config.migrationLockKey").value(20260918))
                .andExpect(jsonPath("$.config.writerLockKey").value(20260919));
    }

    /**
     * P0-3④ D：数据根由装配层（{@code StorageConfiguration}）解析成绝对规范路径后注入，storage
     * 自己不再读 {@code cangshu.*} 绑定面。三条路径必须同源派生，否则移动（临时文件→内容地址）
     * 与对账扫描都会指向不同的根。
     */
    @Test
    @DisplayName("FileStore 的数据根＝装配层解析后的 cangshu.data-root（绝对、规范），临时区与内容地址同源派生")
    void fileStoreUsesResolvedDataRoot() {
        Path root = files.dataRoot();

        assertTrue(root.isAbsolute(), "装配层解析为绝对路径：" + root);
        assertEquals(root.normalize(), root, "装配层解析为规范路径（无 . 与 .. 段）");
        assertTrue(root.toString().replace('\\', '/').endsWith("target/test-data-root"),
                "取自本上下文覆盖的 cangshu.data-root：" + root);
        assertEquals(root.resolve("tmp"), files.tmpDir(), "临时区与内容地址同根（同一文件系统，移动才成立）");

        String storageKey = "sha256/ab/cd/" + "ab".repeat(32);
        assertEquals(root.resolve(storageKey.replace('/', Path.of("").getFileSystem().getSeparator().charAt(0))),
                files.blobPath(storageKey), "相对存储键只在 storage 内解析成数据根下的绝对路径");
    }
}
