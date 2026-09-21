package com.cangshu.job;

import java.time.OffsetDateTime;
import java.time.ZoneOffset;
import org.springframework.stereotype.Component;

/**
 * 后台作业的「最近一次结果」登记（07-运行手册 §6：serve 将同一事件写入结构化日志，
 * 并暴露最近一次作业结果）。单写者门（任务 29）保证同一时刻只有一个写者，故进程内登记足够；
 * 不做跨进程共享存储。全部字段 {@code volatile}：写入发生在调度线程，读取可能发生在请求线程。
 */
@Component
public class MaintenanceRegistry {

    private volatile GcService.GcRunResult lastGc;
    private volatile ReconcileService.ReconcileReport lastReconcile;
    private volatile OffsetDateTime lastGcAt;
    private volatile OffsetDateTime lastReconcileAt;

    public void recordGc(GcService.GcRunResult result) {
        this.lastGc = result;
        this.lastGcAt = OffsetDateTime.now(ZoneOffset.UTC);
    }

    public void recordReconcile(ReconcileService.ReconcileReport report) {
        this.lastReconcile = report;
        this.lastReconcileAt = OffsetDateTime.now(ZoneOffset.UTC);
    }

    public GcService.GcRunResult lastGc() {
        return lastGc;
    }

    public ReconcileService.ReconcileReport lastReconcile() {
        return lastReconcile;
    }

    public OffsetDateTime lastGcAt() {
        return lastGcAt;
    }

    public OffsetDateTime lastReconcileAt() {
        return lastReconcileAt;
    }

    /** 供日志与人工核对的一行摘要（无作业时返回 {@code notRun}）。 */
    public String summary() {
        GcService.GcRunResult gc = lastGc;
        ReconcileService.ReconcileReport reconcile = lastReconcile;
        return "maintenance|gc=" + (gc == null ? "notRun" : gc.summary())
                + "|reconcile=" + (reconcile == null ? "notRun" : reconcile.summary());
    }
}
