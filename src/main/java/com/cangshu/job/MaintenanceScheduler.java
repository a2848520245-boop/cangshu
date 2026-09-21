package com.cangshu.job;

import java.util.concurrent.TimeUnit;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.SmartInitializingSingleton;
import org.springframework.boot.ApplicationArguments;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;

/**
 * 后台作业的启动与周期触发（job 模块，任务 28；04-架构与计划 §5 ③、§8、07-运行手册 §6）。
 *
 * <p>频率按 07 §6 定稿：**启动做完对账后才开始服务**（04 §8 步骤 3）、此后**每小时 GC**、
 * **每日对账**。启动那一次不用 {@code @Scheduled} 而用 {@link SmartInitializingSingleton}：
 * 该回调发生在容器 refresh 的 bean 实例化阶段，**早于 HTTP 连接器开始接受请求**，因此「对账先于服务」
 * 这条顺序是真的，而不是「先服务、再补跑一次对账」。
 *
 * <p>周期任务的 {@code initialDelay} 取一个周期：启动那一次已经跑过，再叠加一次会在启动瞬间重复作业；
 * 顺带让测试进程（生命周期远短于一个周期）不受后台作业干扰。
 *
 * <p>CLI 一次性作业模式（07 §2：{@code --mode=gc|reconcile}，通常与
 * {@code --spring.main.web-application-type=none} 同用）由 {@link MaintenanceCliRunner} 承担；
 * 那种模式下跳过启动作业，避免同一个作业跑两遍。
 */
@Component
public class MaintenanceScheduler implements SmartInitializingSingleton {

    private static final Logger log = LoggerFactory.getLogger(MaintenanceScheduler.class);

    private final GcService gc;
    private final ReconcileService reconcile;
    private final MaintenanceRegistry registry;
    private final ApplicationArguments arguments;

    public MaintenanceScheduler(GcService gc, ReconcileService reconcile, MaintenanceRegistry registry,
            ApplicationArguments arguments) {
        this.gc = gc;
        this.reconcile = reconcile;
        this.registry = registry;
        this.arguments = arguments;
    }

    @Override
    public void afterSingletonsInstantiated() {
        if (arguments.containsOption("mode")) {
            log.info("CANGSHU|job|startup=skipped|reason=cliMode|mode={}", arguments.getOptionValues("mode"));
            return;
        }
        log.info("CANGSHU|job|startup|对账先于服务开始（04 §8 步骤 3）");
        registry.recordReconcile(reconcile.runOnce());
        registry.recordGc(gc.runOnce());
        log.info("CANGSHU|job|{}", registry.summary());
    }

    /** 每小时一次 GC（07 §6）。 */
    @Scheduled(initialDelay = 1, fixedDelay = 1, timeUnit = TimeUnit.HOURS)
    public void hourlyGc() {
        registry.recordGc(gc.runOnce());
    }

    /** 每日一次对账（07 §6）。 */
    @Scheduled(initialDelay = 24, fixedDelay = 24, timeUnit = TimeUnit.HOURS)
    public void dailyReconcile() {
        registry.recordReconcile(reconcile.runOnce());
    }
}
