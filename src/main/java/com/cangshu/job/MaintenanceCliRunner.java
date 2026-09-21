package com.cangshu.job;

import java.util.List;
import org.springframework.boot.ApplicationArguments;
import org.springframework.boot.ApplicationRunner;
import org.springframework.stereotype.Component;

/**
 * CLI 一次性作业入口（job 模块；07-运行手册 §2「CLI 一次性作业」、§6「对账命令…以非零结果结束」）。
 *
 * <p>用法（默认不启 HTTP 容器，故显式关掉 web 类型）：
 *
 * <pre>
 * java -jar cangshu-0.1.0-SNAPSHOT.jar --spring.main.web-application-type=none --mode=reconcile
 * java -jar cangshu-0.1.0-SNAPSHOT.jar --spring.main.web-application-type=none --mode=gc
 * </pre>
 *
 * <p>不带 {@code --mode} 时本类什么都不做（serve 模式的正常路径）。输出为结构化单行摘要；
 * **检出需人工介入的故障时以非零退出**（07 §6）：退出码 {@value #EXIT_NEEDS_ATTENTION} 表示
 * 「作业完成但结果需人工介入」，不同于启动门的 2（锁）与 3（迁移核对）。
 */
@Component
public class MaintenanceCliRunner implements ApplicationRunner {

    /** 作业检出需人工介入时的退出码（07 §7 未给该码，此处取 4 并登记）。 */
    public static final int EXIT_NEEDS_ATTENTION = 4;
    /** 用法错误（未知 mode）。 */
    public static final int EXIT_USAGE = 2;

    private static final List<String> MODES = List.of("gc", "reconcile");

    private final GcService gc;
    private final ReconcileService reconcile;
    private final MaintenanceRegistry registry;

    public MaintenanceCliRunner(GcService gc, ReconcileService reconcile, MaintenanceRegistry registry) {
        this.gc = gc;
        this.reconcile = reconcile;
        this.registry = registry;
    }

    @Override
    public void run(ApplicationArguments args) {
        if (!args.containsOption("mode")) {
            return;   // serve 模式：后台作业由 MaintenanceScheduler 负责
        }
        List<String> values = args.getOptionValues("mode");
        String mode = values == null || values.isEmpty() ? "" : values.get(0);
        if (!MODES.contains(mode)) {
            System.err.println("错误：未知的 --mode=" + mode + "，可用值：" + MODES);
            System.exit(EXIT_USAGE);
            return;
        }
        boolean needsAttention;
        if ("gc".equals(mode)) {
            GcService.GcRunResult result = gc.runOnce();
            registry.recordGc(result);
            System.out.println(result.summary());
            needsAttention = result.needsAttention();
        } else {
            ReconcileService.ReconcileReport report = reconcile.runOnce();
            registry.recordReconcile(report);
            System.out.println(report.summary());
            needsAttention = report.needsAttention();
        }
        System.exit(needsAttention ? EXIT_NEEDS_ATTENTION : 0);
    }
}
