# 仓鼠 CangShu

仓鼠是个人资源管理 PRM 的 M1：单机单用户最小闭环。

## 技术栈

Java 21 + Spring Boot 3.5.x + Maven + MyBatis-Plus + PostgreSQL 17 + Vue 3 + TypeScript + Vite。

规划采用模块化单体，包含六个模块：`ingest`、`catalog`、`storage`、`search`、`job`、`api`。当前均为占位，尚未实现。

## 原型仓库与验收证据

原型仓库：[cangshu-mvp](https://github.com/a2848520245-boop/cangshu-mvp)

原型已冻结 tag：`v0.1-mvp-prototype`。

原型验收证据：24 项接口冒烟测试通过，12 项浏览器端到端测试通过。

## 文档说明

分层与架构文档维护在个人笔记库。本仓库只放工程产物与链接说明。

## 状态

M1 骨架待建，先占位。
