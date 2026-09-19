# 仓鼠 CangShu

仓鼠是个人资源管理 PRM 项目。M1 范围为单机、单用户、本地或局域网的最小资源闭环。

## 技术与范围

Java 21、Spring Boot 3.5、Maven、MyBatis-Plus、PostgreSQL 17，模块化单体。
M1 无前端；Vue 3、TypeScript、Vite 属后续规划。多用户、外网、目录导入、分片与秒传不在 M1。

## 构建与运行（任务 2 最小工程）

- 构建：`JAVA_HOME` 指向 JDK 21 后执行 `mvn -B -ntp package`（默认端口 8080）。
- 启动：`java -jar target/cangshu-0.1.0-SNAPSHOT.jar`。
- 健康检查：`GET /actuator/health` → `{"status":"UP"}`。
- 最小接口：`GET /api/health` → 服务状态与六个定稿配置键的生效值（数据根为解析后的规范绝对路径）；
  启动日志同时输出一行 `CANGSHU|config|dataRoot=…` 记录解析结果。
- 配置键与环境变量映射见《M1-运行手册》§1（知识库 `10-常用/仓鼠/07-M1-运行手册`）：
  `cangshu.data-root`→`CANGSHU_DATA_ROOT`、`cangshu.upload.max-size`→`CANGSHU_UPLOAD_MAX_SIZE`、
  `cangshu.trash.retention`→`CANGSHU_TRASH_RETENTION`、`cangshu.migration.dir`→`CANGSHU_MIGRATION_DIR`；
  `cangshu.migration.lock-key` 与 `cangshu.writer.lock-key` 是协议常量，不支持运行配置覆盖。
- 数据根：开发默认 `./var/data-root`（相对运行目录），目录由存储层在后续任务创建，本任务不落盘。
- 数据库：任务 2 不引入数据源；数据模型与迁移分别属任务 12 与任务 30。

## 工作入口

先读 [AGENTS.md](AGENTS.md)。设计与契约维护在个人笔记库：
`E:/詩/Documents/NOTE/obsidian-kb-starter/10-常用/仓鼠/仓鼠项目-总览.md`。
任务与验收以该目录的 `M1-任务表.md` 为准，不能从旧报告推断当前代码状态。

文档治理工具与检查命令：[tools/doc_governance/README.md](tools/doc_governance/README.md)。
本仓的工具测试结果只证明治理工具，不代表 M1 业务功能验收。

## 冻结原型

原型仓：[cangshu-mvp](https://github.com/a2848520245-boop/cangshu-mvp)，冻结标记 `v0.1-mvp-prototype`。
原型与 M1 的实现和验收分别管理，不把原型测试当作 M1 测试。
