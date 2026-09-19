-- V2__search_indexes.sql（脚本只增不改；DDL 与 schema_version 记账同一事务）
-- 依据：《03-M1-SPEC》REQ-M1-04／05（文件名包含匹配、标签过滤；不引入独立检索引擎）与 §3
--       可替换项「模糊匹配是否启用扩展」；ADR-0001 §一.2（PostgreSQL：检索先字段索引 ＋ pg_trgm）；
--       《08-M1-验收规范》ACC-G1（典型索引查询 p95 < 300ms，执行计划不得全表扫描）。
-- 目标：文件名包含匹配（ILIKE '%…%'）与 jsonb 标签包含（@>）在百万级元数据下走索引
--       （trigram GIN 位图扫描／jsonb_path_ops GIN 位图扫描），不做顺序扫描。
-- 执行：人工持迁移锁（07-运行手册 §4）：
--   psql -h <host> -U <user> -d <database> -v script_sha256=<本文件SHA-256> -f V2__search_indexes.sql

BEGIN;

-- pg_trgm 自 PostgreSQL 13 起为可信扩展，CREATE EXTENSION 可在事务内执行
CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- 文件名包含匹配：trigram GIN（ILIKE 模式可提取 trigram 走位图索引扫描）
CREATE INDEX IF NOT EXISTS idx_resource_name_trgm
    ON cangshu_m1.resource USING gin (name gin_trgm_ops);

-- 标签过滤：jsonb_path_ops 支持 @> 包含算子（比 jsonb_ops 更小更快；M1 不用存在性算子）
CREATE INDEX IF NOT EXISTS idx_resource_tags_jsonb
    ON cangshu_m1.resource USING gin (tags jsonb_path_ops);

-- 记账与 DDL 同事务；script_sha256 由执行方以 psql 变量传入（本文件整体 SHA-256）
INSERT INTO cangshu_m1.schema_version (version, script_name, executed_at, script_sha256)
VALUES ('V2', 'V2__search_indexes.sql', now(), :'script_sha256');

COMMIT;
