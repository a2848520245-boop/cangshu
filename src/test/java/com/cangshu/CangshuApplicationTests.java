package com.cangshu;

import org.junit.jupiter.api.Test;
import org.springframework.boot.test.context.SpringBootTest;

/**
 * 最小工程：上下文可加载。
 *
 * <p>任务 28 起，启动序列要求「完成对账后才允许开始服务」（04-架构与计划 §8 步骤 3），
 * 因此上下文加载本身就会连库执行启动对账与 GC——本用例不再是「不触库」的纯启动测试。
 * 这与该设计一致（任务 29／30 落地后还会把「拿不到锁／迁移核对不符」变成退出码 2／3 的硬拒启），
 * 故此处显式指向测试库，不依赖开发库。
 */
@SpringBootTest(properties = {
        "spring.datasource.url=jdbc:postgresql://127.0.0.1:5432/cangshu_test?currentSchema=cangshu_m1",
        "spring.datasource.username=postgres",
        "spring.datasource.password=postgres"
})
class CangshuApplicationTests {

    @Test
    void contextLoads() {
    }
}
