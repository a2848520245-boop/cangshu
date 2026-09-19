# 仓鼠 CangShu

仓鼠是个人资源管理 PRM 项目。M1 范围为单机、单用户、本地或局域网的最小资源闭环。

## 技术与范围

Java 21、Spring Boot 3.5、Maven、MyBatis-Plus、PostgreSQL 17，模块化单体。
M1 无前端；Vue 3、TypeScript、Vite 属后续规划。多用户、外网、目录导入、分片与秒传不在 M1。

## 构建与运行

- 构建：`JAVA_HOME` 指向 JDK 21 后执行 `mvn -B -ntp -Dmaven.repo.local=var/m2repo package`（默认端口 8080）。
- 启动：`java -jar target/cangshu-0.1.0-SNAPSHOT.jar`。
- 健康检查：`GET /actuator/health` → `{"status":"UP"}`（引入数据源后，健康概要含数据库可达性）。
- 最小接口：`GET /api/health` → 服务状态与六个定稿配置键的生效值（数据根为解析后的规范绝对路径）；
  启动日志同时输出一行 `CANGSHU|config|dataRoot=…` 记录解析结果。
- 配置键与环境变量映射见《M1-运行手册》§1（知识库 `10-常用/仓鼠/07-M1-运行手册`）：
  `cangshu.data-root`→`CANGSHU_DATA_ROOT`、`cangshu.upload.max-size`→`CANGSHU_UPLOAD_MAX_SIZE`、
  `cangshu.trash.retention`→`CANGSHU_TRASH_RETENTION`、`cangshu.migration.dir`→`CANGSHU_MIGRATION_DIR`；
  `cangshu.migration.lock-key` 与 `cangshu.writer.lock-key` 是协议常量，不支持运行配置覆盖。
- 上传资源（任务 3）：`POST /api/resources`，`multipart/form-data`，字段 `file`（必填、单文件）；
  服务端流式接收并同时计算 SHA-256（不整文件读入内存）；相同内容复用既有物理内容（响应带
  `deduplicated`／`contentId`）；错误码 400／409（含 `reason`）／413／503 见《M1-接口契约》§2。
- 资源列表与检索（任务 4）：`GET /api/resources?name=&tag=&page=1&size=20`，`name` 为文件名包含匹配
  （大小写不敏感，pg_trgm GIN），`tag` 为标签过滤（jsonb `@>` GIN），排序固定 id DESC（UUIDv7 时间有序）；
  `page`／`size` 缺省 1／20，小于 1 → 400。
- 资源详情（任务 4）：`GET /api/resources/{id}` → 200 资源对象另带 `contentId`（内容关联的引用关系
  展示）；不存在或已在回收站 → 404；ID 非法 → 400。回收站中的资源对普通列表／详情不可见。
- 资源下载与预览（任务 5）：`GET /api/resources/{id}/content`，默认 `attachment`，文件名按
  RFC 5987 编码（`filename*=UTF-8''…`，中文文件名原样保留）；`?inline=1` 改为浏览器内联预览，
  只改响应处置头、不改字节与摘要，`inline` 仅接受 `1`，其他取值 → 400。
  不存在或已在回收站（软删）→ 404；盘上字节缺失或与内容身份不符 → 500 拒绝下载，绝不返回空文件。

### 数据库（任务 3 起）

- 开发轨默认：本机 PostgreSQL 17（`jdbc:postgresql://127.0.0.1:5432/cangshu`，可用 `CANGSHU_DB_URL`／
  `CANGSHU_DB_USER`／`CANGSHU_DB_PASSWORD` 覆盖）；表位于隔离 schema `cangshu_m1`。
- 首次初始化（禁空库降级）：建库 → 人工按序执行迁移脚本（DDL 与记账同事务）：
  `psql -d <库> -v script_sha256=<脚本文件 SHA-256> -f db/migration/V1__init.sql`，
  再对 V2__search_indexes.sql 重复同一流程（检索索引：pg_trgm ＋ jsonb_path_ops）；
  脚本只增不改，台账 `schema_version` 记录版本与脚本摘要。
- 测试前提：`mvn test` 的集成测试需要本机 PostgreSQL 17 运行，且测试库（默认 `cangshu_test`）
  已按上述步骤执行过 `V1__init.sql` 与 `V2__search_indexes.sql`。

## 工作入口

先读 [AGENTS.md](AGENTS.md)。设计与契约维护在个人笔记库：
`E:/詩/Documents/NOTE/obsidian-kb-starter/10-常用/仓鼠/仓鼠项目-总览.md`。
任务与验收以该目录的 `M1-任务表.md` 为准，不能从旧报告推断当前代码状态。

文档治理工具与检查命令：[tools/doc_governance/README.md](tools/doc_governance/README.md)。
本仓的工具测试结果只证明治理工具，不代表 M1 业务功能验收。

## 冻结原型

原型仓：[cangshu-mvp](https://github.com/a2848520245-boop/cangshu-mvp)，冻结标记 `v0.1-mvp-prototype`。
原型与 M1 的实现和验收分别管理，不把原型测试当作 M1 测试。
