-- V1__init.sql（脚本只增不改；DDL 与 schema_version 记账同一事务）
-- 依据：《06-M1-数据契约》§1–§6、§9（五表、字段、约束、索引、状态取值域）；
--       《04-M1-架构与计划》§3（内容键 sha256/ab/cd/<digest>、算法命名空间三处取值）；
--       ADR-0001 §三–§七（T1/T2/T3/T4）。
-- 隔离 schema：cangshu_m1；表名全部 schema 限定，不依赖 search_path（06 总则）。
-- 执行：人工持迁移锁（07-运行手册 §4）：
--   psql -h <host> -U <user> -d <database> -v script_sha256=<本文件SHA-256> -f V1__init.sql
--   台账 script_sha256 记录本文件整体的 SHA-256，与 08-验收规范 §6「脚本 SHA-256 与台账一致」对应。

BEGIN;

CREATE SCHEMA IF NOT EXISTS cangshu_m1;

-- ── content：内容身份（算法＋摘要＋大小三元组），不含任何二进制列（06 §3）──
CREATE TABLE IF NOT EXISTS cangshu_m1.content (
    id              uuid        PRIMARY KEY,
    hash_algorithm  text        NOT NULL,
    digest          text        NOT NULL,
    size_bytes      bigint      NOT NULL CHECK (size_bytes >= 0),
    status          text        NOT NULL CHECK (status IN ('PENDING','READY','FAILED','RECLAIM_PENDING','RECLAIMING','RECLAIMED')),
    created_at      timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT uq_content_identity UNIQUE (hash_algorithm, digest, size_bytes)
);
-- 并发锁键与冲突查找＝算法＋摘要（不含大小）：走这条普通索引（04 §3、06 §3）
CREATE INDEX IF NOT EXISTS idx_content_digest ON cangshu_m1.content (hash_algorithm, digest);
CREATE INDEX IF NOT EXISTS idx_content_status ON cangshu_m1.content (status);

-- ── location：位置（后端＋相对存储键；业务层不依赖绝对路径）（06 §5）──
CREATE TABLE IF NOT EXISTS cangshu_m1.location (
    id              uuid PRIMARY KEY,
    content_id      uuid NOT NULL REFERENCES cangshu_m1.content (id),
    storage_backend text NOT NULL,
    storage_key     text NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_location_content_id ON cangshu_m1.location (content_id);

-- ── resource：逻辑资源条目（软删等价约束；保护引用计数含回收站行）（06 §2）──
CREATE TABLE IF NOT EXISTS cangshu_m1.resource (
    id          uuid        PRIMARY KEY,
    name        text        NOT NULL,
    size_bytes  bigint      NOT NULL CHECK (size_bytes >= 0),
    mime_type   text,
    content_id  uuid        NOT NULL REFERENCES cangshu_m1.content (id),
    tags        jsonb       NOT NULL DEFAULT '[]'::jsonb,
    status      text        NOT NULL CHECK (status IN ('PENDING','READY','FAILED','DELETED')),
    deleted_at  timestamptz,
    expire_at   timestamptz,
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT ck_resource_softdelete CHECK (
        (status <> 'DELETED' AND deleted_at IS NULL AND expire_at IS NULL)
        OR (status = 'DELETED' AND deleted_at IS NOT NULL AND expire_at IS NOT NULL)
    )
);
-- 引用计数为实时计数：普通索引、非唯一（06 §2、§8）
CREATE INDEX IF NOT EXISTS idx_resource_content_id ON cangshu_m1.resource (content_id);
CREATE INDEX IF NOT EXISTS idx_resource_status ON cangshu_m1.resource (status);
CREATE INDEX IF NOT EXISTS idx_resource_expire_at ON cangshu_m1.resource (expire_at);

-- ── content_conflict：冲突审计（先比大小、再比字节，两步都在移动前；原行原字节不动）（06 §4）──
CREATE TABLE IF NOT EXISTS cangshu_m1.content_conflict (
    id                    uuid        PRIMARY KEY,
    hash_algorithm        text        NOT NULL,
    digest                text        NOT NULL,
    existing_content_id   uuid,
    existing_size_bytes   bigint,
    incoming_size_bytes   bigint      NOT NULL CHECK (incoming_size_bytes >= 0),
    existing_storage_key  text,
    incoming_storage_key  text        NOT NULL,
    reason                text        NOT NULL,
    created_at            timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_content_conflict_digest ON cangshu_m1.content_conflict (hash_algorithm, digest);

-- ── schema_version：迁移台账（版本／脚本名／时刻／脚本 SHA-256；无迁移修复引擎）（06 §6）──
CREATE TABLE IF NOT EXISTS cangshu_m1.schema_version (
    version       text        PRIMARY KEY,
    script_name   text        NOT NULL,
    executed_at   timestamptz NOT NULL DEFAULT now(),
    script_sha256 text        NOT NULL
);

-- 记账与 DDL 同事务；script_sha256 由执行方以 psql 变量传入（本文件整体 SHA-256）
INSERT INTO cangshu_m1.schema_version (version, script_name, executed_at, script_sha256)
VALUES ('V1', 'V1__init.sql', now(), :'script_sha256');

COMMIT;
