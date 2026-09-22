#!/usr/bin/env bash
# 仓鼠 M1 人工迁移锁协议（唯一实现：本机 psql 与容器 psql 两个传输共用）
#
# 规范依据（原文）：
#   · 07-运行手册 §4「迁移操作」：「人工持迁移锁执行；DDL 与记账同一事务，出错整体回滚。」
#   · 07-运行手册 §1「锁键纪律」：「CLI、serve、人工迁移必须遵循同一锁协议；迁移操作需确保业务写者已退出。」
#     同节登记：cangshu.migration.lock-key ＝ 20260918、cangshu.writer.lock-key ＝ 20260919；
#     两者是协议常量，不支持普通环境变量或运行配置覆盖。
#   · 07-运行手册 §7「启动与退出码」：「未拿到 DB 会话锁或数据根文件锁 → 停写，退出码 2，不写任何字节。」
#   · ADR-0001 §四 ^dec-t2：「单写者门：以 DB 会话锁 ＋ 数据根文件锁 拒绝第二写者，失锁即停写（退出码 2）。」
#   · ADR-0001 §七 ^dec-t3：「人工持迁移锁执行；DDL 与记账同事务、遇错整体回滚；脚本只增不改。」
#
# 为什么用会话级锁，而不是把事务级锁塞进「DDL＋记账」那个事务：
#   db/migration 的每个脚本自己 BEGIN/COMMIT（脚本只增不改，不能改），pg_advisory_xact_lock 会在 V1
#   提交的那一刻就释放，既盖不住后续脚本，也保不住「迁移期间持有写者锁」；会话级锁覆盖整段迁移，
#   且随会话结束（正常结束、报错退出、被强杀）由 PostgreSQL 自动释放，不会残留。DDL 与 schema_version
#   记账仍在脚本自己的同一个事务里（既有行为不变）。
#
# 退出码（07 §7「未拿锁＝2」语义；同步写在 tools/migration-gate/README.md）：
#   0 ＝ 成功；1 ＝ 迁移失败（脚本报错，整体回滚）；2 ＝ 未拿锁（迁移锁或写者锁，不写任何字节）。

# ── 协议常量（07 §1 登记值，与 CangshuProperties.MIGRATION_LOCK_KEY／WRITER_LOCK_KEY 一致）──
MIGRATION_LOCK_KEY=20260918
WRITER_LOCK_KEY=20260919

# ── 结构化标记（与 WriterGate 的 CANGSHU|writer-gate|* 同风格，便于取证脚本断言）──
MIGRATION_ACQUIRED_MARKER="CANGSHU|migration|lock-acquired"
MIGRATION_RELEASED_MARKER="CANGSHU|migration|lock-released"
MIGRATION_DENIED_MARKER="CANGSHU|migration|denied"
MIGRATION_SCRIPT_MARKER="CANGSHU|migration|script"
MIGRATION_LEDGER_MARKER="CANGSHU|migration|ledger"
MIGRATION_PREFLIGHT_MARKER="CANGSHU|migration|preflight"

# ── 退出码 ──
MIGRATION_EXIT_OK=0
MIGRATION_EXIT_FAILED=1
MIGRATION_EXIT_LOCK_DENIED=2

# psql 元命令前缀写成变量：printf 的格式串会把 \e 当成转义序列，绕开这一坑。
MIGRATION_PSQL_ECHO='\echo'
MIGRATION_PSQL_SET='\set'

# 打印「锁协议前奏」SQL：在改动目标库之前取两把锁（迁移锁 → 写者锁），非阻塞，取不到即拒绝。
migration_lock_prologue() {
    cat <<SQL
-- ══ 人工迁移锁协议前奏（07 §4／§7；ADR-0001 §四 ^dec-t2、§七 ^dec-t3）══
-- 取锁顺序：① 迁移锁 ${MIGRATION_LOCK_KEY}（先占住本次迁移）→ ② 写者锁 ${WRITER_LOCK_KEY}（确保业务写者已退出）。
-- 两把都用 pg_try_advisory_lock（非阻塞）：取不到立刻拒绝，不等待、不写任何字节（07 §7 退出码 2）。
-- 会话级锁：整段迁移期间有效；会话结束（含失败／被强杀）由 PostgreSQL 自动释放，不残留。
-- 锁键是协议常量，不支持环境变量或运行配置覆盖（07 §1 锁键纪律）。
\set ON_ERROR_STOP on
DO \$cangshu_migration_lock\$
BEGIN
    IF NOT pg_try_advisory_lock(${MIGRATION_LOCK_KEY}) THEN
        RAISE EXCEPTION '${MIGRATION_DENIED_MARKER}|reason=migration-lock|lockKey=${MIGRATION_LOCK_KEY}|detail=迁移锁已被持有：已有迁移在执行，请等它结束后重试（退出码 ${MIGRATION_EXIT_LOCK_DENIED}，07 §7）';
    END IF;
    IF NOT pg_try_advisory_lock(${WRITER_LOCK_KEY}) THEN
        RAISE EXCEPTION '${MIGRATION_DENIED_MARKER}|reason=writer-lock|lockKey=${WRITER_LOCK_KEY}|detail=写者锁被活跃写者持有（serve／CLI 实例在跑）：迁移操作需确保业务写者已退出（07 §1），请先停掉 serve 实例再迁移（退出码 ${MIGRATION_EXIT_LOCK_DENIED}，07 §7）';
    END IF;
END
\$cangshu_migration_lock\$;
\echo '${MIGRATION_ACQUIRED_MARKER}|migrationKey=${MIGRATION_LOCK_KEY}|writerKey=${WRITER_LOCK_KEY}|mode=pg_try_advisory_lock|scope=session'
SQL
}

# 打印「锁协议尾声」SQL：输出台账，然后显式释放两把锁，并按**实际返回值**打印释放结果。
#
# 为什么要把返回值当回事（P0-3 收尾补丁 P3）：pg_advisory_unlock 返回 false 说明本会话当时**并不持有**
# 那把锁——锁从未取到（不该走到这里）、被同一会话解锁过、或被某段 SQL 解掉（例如 pg_advisory_unlock_all）。
# 此时还照旧打印「锁已释放」就是假证据：日志说锁没了，而锁可能仍在别人手上。所以 token 一律取自返回值，
# 返回 false 时也打印标记但 released=false，由 migrate.sh 的收尾提示要求人工核查。迁移本身仍按成功计数
# ——07 §7 的退出码 2 只覆盖「没拿到锁」，不覆盖「收尾释放返回 false」（见 tools/migration-gate/README.md）。
migration_lock_epilogue() {
    cat <<SQL
-- ══ 人工迁移锁协议尾声：台账 ＋ 显式释放两把锁 ══
\echo '${MIGRATION_LEDGER_MARKER}|begin'
\pset format unaligned
\pset tuples_only on
SELECT version || ' | ' || script_name || ' | ' || script_sha256 FROM cangshu_m1.schema_version ORDER BY version;
\echo '${MIGRATION_LEDGER_MARKER}|end'
-- 两把锁各自只解锁一次（会话级锁按持有次数计数，多调一次会把 false 误当成「没释放」）：先把返回值
-- 收进 psql 变量，再由它派生两行日志——先给验证脚本认的旧形状，再给带 released 的新标记。
SELECT pg_advisory_unlock(${MIGRATION_LOCK_KEY})::text AS migration_lock,
       pg_advisory_unlock(${WRITER_LOCK_KEY})::text AS writer_lock
\gset cangshu_release_
SELECT 'migration_lock_released=' || :'cangshu_release_migration_lock'
    || '|writer_lock_released=' || :'cangshu_release_writer_lock';
SELECT '${MIGRATION_RELEASED_MARKER}|migrationKey=${MIGRATION_LOCK_KEY}|writerKey=${WRITER_LOCK_KEY}'
    || '|released=' || ((:'cangshu_release_migration_lock')::boolean
        AND (:'cangshu_release_writer_lock')::boolean)::text
    || '|migrationLockReleased=' || :'cangshu_release_migration_lock'
    || '|writerLockReleased=' || :'cangshu_release_writer_lock';
\pset tuples_only off
\pset format aligned
SQL
}

# 计算某个迁移脚本的 SHA-256（台账口径＝宿主上该文件的摘要，与 psql 变量 script_sha256 同源）。
migration_script_sha256() {
    local path="$1"
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$path" | cut -d' ' -f1
        return 0
    fi
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$path" | cut -d' ' -f1
        return 0
    fi
    printf '%s\n' '错误：需要 sha256sum 或 shasum 来计算脚本 SHA-256（台账记录宿主文件摘要）' >&2
    return 1
}

# 在启动 psql 前冻结迁移清单。版本必须是正整数，脚本名使用可安全进入 SQL/日志的文件名字符集；
# 同一数值版本只能出现一次，后续 SQL 不再重新枚举目录。
migration_manifest_build() {
    local migration_dir="$1"
    local script name version sha path previous_version
    local -a entries=()

    MIGRATION_VERSIONS=()
    MIGRATION_NAMES=()
    MIGRATION_SHAS=()
    MIGRATION_PATHS=()
    MIGRATION_MANIFEST_JSON=''

    for script in "$migration_dir"/V*.sql; do
        [ -e "$script" ] || continue
        if [ ! -f "$script" ]; then
            printf '%s\n' "错误：迁移路径不是普通文件：$script" >&2
            return 1
        fi
        name="$(basename "$script")"
        if [[ ! "$name" =~ ^(V[1-9][0-9]*)__([A-Za-z0-9][A-Za-z0-9._-]*)\.sql$ ]]; then
            printf '%s\n' "错误：迁移文件名不符合 V<正整数>__<非空名>.sql：$name" >&2
            return 1
        fi
        version="${BASH_REMATCH[1]}"
        sha="$(migration_script_sha256 "$script")" || return 1
        entries+=("${version#V}"$'\t'"$version"$'\t'"$name"$'\t'"$sha"$'\t'"$script")
    done

    if [ "${#entries[@]}" -eq 0 ]; then
        printf '%s\n' "错误：$migration_dir 下没有 V*.sql 迁移脚本" >&2
        return 1
    fi

    previous_version=''
    while IFS=$'\t' read -r _ version name sha path; do
        if [ -n "$previous_version" ] && [ "$version" = "$previous_version" ]; then
            printf '%s\n' "错误：迁移版本重复：$version（脚本 $name）" >&2
            return 1
        fi
        previous_version="$version"
        MIGRATION_VERSIONS+=("$version")
        MIGRATION_NAMES+=("$name")
        MIGRATION_SHAS+=("$sha")
        MIGRATION_PATHS+=("$path")
    done < <(printf '%s\n' "${entries[@]}" | sort -t $'\t' -k1,1n)

    MIGRATION_MANIFEST_JSON='['
    local i
    for i in "${!MIGRATION_VERSIONS[@]}"; do
        [ "$i" -eq 0 ] || MIGRATION_MANIFEST_JSON+=','
        MIGRATION_MANIFEST_JSON+=$(printf '{"version":"%s","script_name":"%s","script_sha256":"%s"}' \
            "${MIGRATION_VERSIONS[$i]}" "${MIGRATION_NAMES[$i]}" "${MIGRATION_SHAS[$i]}")
    done
    MIGRATION_MANIFEST_JSON+=']'
    return 0
}

# 在同一个已持锁 psql 会话内完成全部历史校验。该段只读 catalog/台账，不执行业务 DDL。
migration_preflight_stream() {
    local manifest="${MIGRATION_MANIFEST_JSON:?迁移清单尚未冻结}"
    local first_version="${MIGRATION_VERSIONS[0]:?迁移清单为空}"
    cat <<SQL
${MIGRATION_PSQL_ECHO} '${MIGRATION_PREFLIGHT_MARKER}|begin'
DO \$cangshu_migration_preflight\$
DECLARE
    local_manifest jsonb := '${manifest}'::jsonb;
    local_count integer := jsonb_array_length('${manifest}'::jsonb);
    ledger_count bigint;
    ledger_distinct_count bigint;
    ledger_kind "char";
    ledger_row record;
    local_row record;
    expected_row record;
BEGIN
    IF to_regclass('cangshu_m1.schema_version') IS NULL THEN
        IF EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'cangshu_m1') THEN
            RAISE EXCEPTION '${MIGRATION_PREFLIGHT_MARKER}|preflight-denied|reason=ledger-missing|detail=cangshu_m1 schema 已存在但 schema_version 台账缺失，拒绝新增 DDL';
        END IF;
        IF '${first_version}' <> 'V1' THEN
            RAISE EXCEPTION '${MIGRATION_PREFLIGHT_MARKER}|preflight-denied|reason=bootstrap-version|detail=空库首个迁移必须是 V1，实际为 ${first_version}';
        END IF;
    ELSE
        SELECT c.relkind INTO ledger_kind
          FROM pg_class c
          JOIN pg_namespace n ON n.oid = c.relnamespace
         WHERE n.nspname = 'cangshu_m1' AND c.relname = 'schema_version';
        IF ledger_kind IS DISTINCT FROM 'r' THEN
            RAISE EXCEPTION '${MIGRATION_PREFLIGHT_MARKER}|preflight-denied|reason=ledger-kind|detail=schema_version 不是普通表，拒绝迁移';
        END IF;

        SELECT count(*), count(DISTINCT version)
          INTO ledger_count, ledger_distinct_count
          FROM cangshu_m1.schema_version;
        IF ledger_count <> ledger_distinct_count THEN
            RAISE EXCEPTION '${MIGRATION_PREFLIGHT_MARKER}|preflight-denied|reason=ledger-duplicate-version|detail=schema_version 存在重复版本';
        END IF;
        FOR ledger_row IN SELECT version, script_name, script_sha256 FROM cangshu_m1.schema_version LOOP
            IF NOT EXISTS (
                SELECT 1 FROM jsonb_to_recordset(local_manifest)
                    AS m(version text, script_name text, script_sha256 text)
                 WHERE m.version = ledger_row.version
            ) THEN
                RAISE EXCEPTION '${MIGRATION_PREFLIGHT_MARKER}|preflight-denied|reason=ledger-script-missing|version=%|detail=台账存在该版本但盘上缺少对应脚本', ledger_row.version;
            END IF;
        END LOOP;

        IF ledger_count > local_count THEN
            RAISE EXCEPTION '${MIGRATION_PREFLIGHT_MARKER}|preflight-denied|reason=ledger-extra-row|detail=台账行数 % 超过盘上迁移脚本数 %', ledger_count, local_count;
        END IF;

        FOR local_row IN
            SELECT m.value->>'version' AS version,
                   m.value->>'script_name' AS script_name,
                   m.value->>'script_sha256' AS script_sha256,
                   m.ordinality
              FROM jsonb_array_elements(local_manifest) WITH ORDINALITY AS m(value, ordinality)
             ORDER BY m.ordinality
        LOOP
            SELECT version, script_name, script_sha256
              INTO expected_row
              FROM cangshu_m1.schema_version
             WHERE version = local_row.version;
            IF local_row.ordinality <= ledger_count THEN
                IF NOT FOUND THEN
                    RAISE EXCEPTION '${MIGRATION_PREFLIGHT_MARKER}|preflight-denied|reason=ledger-prefix-gap|version=%|detail=台账不是盘上脚本的连续前缀，缺少该版本', local_row.version;
                END IF;
                IF expected_row.script_name IS DISTINCT FROM local_row.script_name THEN
                    RAISE EXCEPTION '${MIGRATION_PREFLIGHT_MARKER}|preflight-denied|reason=script-name-drift|version=%|期望脚本名=%|实际脚本名=%', local_row.version, local_row.script_name, expected_row.script_name;
                END IF;
                IF expected_row.script_sha256 IS DISTINCT FROM local_row.script_sha256 THEN
                    RAISE EXCEPTION '${MIGRATION_PREFLIGHT_MARKER}|preflight-denied|reason=digest-drift|version=%|期望摘要=%|实际摘要=%|detail=摘要不一致', local_row.version, local_row.script_sha256, expected_row.script_sha256;
                END IF;
            ELSIF FOUND THEN
                RAISE EXCEPTION '${MIGRATION_PREFLIGHT_MARKER}|preflight-denied|reason=ledger-not-prefix|version=%|detail=台账版本不在本地脚本连续前缀中', local_row.version;
            END IF;
        END LOOP;
    END IF;
END
\$cangshu_migration_preflight\$;
${MIGRATION_PSQL_ECHO} '${MIGRATION_PREFLIGHT_MARKER}|ok'
SELECT CASE WHEN to_regclass('cangshu_m1.schema_version') IS NULL THEN 'true' ELSE 'false' END AS bootstrap
\gset migration_
SQL
}

# 预检成功后为每个冻结清单项设置 run_Vn；已登记且三元组一致的版本只输出 skip。
migration_pending_script_stream() {
    local i version name sha path
    for i in "${!MIGRATION_VERSIONS[@]}"; do
        version="${MIGRATION_VERSIONS[$i]}"
        name="${MIGRATION_NAMES[$i]}"
        sha="${MIGRATION_SHAS[$i]}"
        path="${MIGRATION_PATHS[$i]}"
        cat <<SQL
\if :migration_bootstrap
\set run_${version} true
\else
SELECT CASE WHEN EXISTS (SELECT 1 FROM cangshu_m1.schema_version WHERE version = '${version}') THEN 'false' ELSE 'true' END AS "run_${version}"
\gset
\endif
\if :run_${version}
${MIGRATION_PSQL_ECHO} '${MIGRATION_SCRIPT_MARKER}|version=${version}|name=${name}|sha256=${sha}|action=run'
${MIGRATION_PSQL_SET} script_sha256 ${sha}
SQL
        cat "$path"
        cat <<SQL

\else
${MIGRATION_PSQL_ECHO} '${MIGRATION_SCRIPT_MARKER}|version=${version}|name=${name}|sha256=${sha}|action=skip'
\endif
SQL
    done
}

# 同一持锁会话先预检，再按冻结清单执行或跳过。
migration_driver_stream() {
    migration_preflight_stream
    migration_pending_script_stream
}

# 裸执行入口已废弃，拒绝绕过预检。
migration_scripts_stream() {
    printf '%s\n' '错误：migration_scripts_stream 已废弃；请先冻结清单并调用 migration_driver_stream' >&2
    return 1
}

# 旧接口仅供历史证据对照，生产入口不调用。
migration_scripts_stream_legacy() {
    local migration_dir="$1"
    local found=0 script sha name
    for script in "$migration_dir"/V*.sql; do
        [ -e "$script" ] || continue
        found=1
        name="$(basename "$script")"
        sha="$(migration_script_sha256 "$script")"
        printf '%s\n' "${MIGRATION_PSQL_ECHO} '  执行 ${name}（sha256=${sha:0:12}…）'"
        printf '%s\n' "${MIGRATION_PSQL_ECHO} '${MIGRATION_SCRIPT_MARKER}|name=${name}|sha256=${sha}'"
        printf '%s\n' "${MIGRATION_PSQL_SET} script_sha256 ${sha}"
        cat "$script"
        printf '\n'
    done
    if [ "$found" -eq 0 ]; then
        printf '%s\n' "错误：$migration_dir 下没有 V*.sql 迁移脚本" >&2
        return 1
    fi
    return 0
}

# 会话日志 → 拒绝原因（reason=migration-lock／reason=writer-lock）；没有拒绝标记时输出空串。
migration_denied_reason() {
    local log_file="$1"
    if [ -f "$log_file" ]; then
        grep -o -m 1 "${MIGRATION_DENIED_MARKER}|reason=[A-Za-z-]*" "$log_file" || true
    fi
    return 0
}

# psql 退出码 ＋ 会话日志 → 本脚本退出码（0／1／2；2＝未拿锁，07 §7）。
migration_exit_code() {
    local psql_status="$1"
    local log_file="$2"
    if [ "$psql_status" -eq 0 ]; then
        printf '%s' "${MIGRATION_EXIT_OK}"
        return 0
    fi
    if [ -n "$(migration_denied_reason "$log_file")" ]; then
        printf '%s' "${MIGRATION_EXIT_LOCK_DENIED}"
        return 0
    fi
    printf '%s' "${MIGRATION_EXIT_FAILED}"
    return 0
}
