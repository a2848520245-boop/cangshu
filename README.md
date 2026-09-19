# 仓鼠 CangShu

仓鼠是个人资源管理 PRM 项目。M1 范围为单机、单用户、本地或局域网的最小资源闭环。

## 技术与范围

Java 21、Spring Boot 3.5、Maven、MyBatis-Plus、PostgreSQL 17，模块化单体。
M1 无前端；Vue 3、TypeScript、Vite 属后续规划。多用户、外网、目录导入、分片与秒传不在 M1。

## 工作入口

先读 [AGENTS.md](AGENTS.md)。设计与契约维护在个人笔记库：
`E:/詩/Documents/NOTE/obsidian-kb-starter/10-常用/仓鼠/仓鼠项目-总览.md`。
任务与验收以该目录的 `M1-任务表.md` 为准，不能从旧报告推断当前代码状态。

文档治理工具与检查命令：[tools/doc_governance/README.md](tools/doc_governance/README.md)。
本仓的工具测试结果只证明治理工具，不代表 M1 业务功能验收。

## 冻结原型

原型仓：[cangshu-mvp](https://github.com/a2848520245-boop/cangshu-mvp)，冻结标记 `v0.1-mvp-prototype`。
原型与 M1 的实现和验收分别管理，不把原型测试当作 M1 测试。
