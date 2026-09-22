#!/usr/bin/env bash
# 仓鼠 M1 人工执行迁移（07-运行手册 §4「迁移操作」；开发态默认走本机 PostgreSQL 客户端）
#
# 用法：
#   bash scripts/migrate.sh
#   CANGSHU_MIGRATE_PSQL='psql -h 127.0.0.1 -p 5432 -U postgres -d cangshu' bash scripts/migrate.sh
#
# 语义（07 §4 ＋ §7）：
#   - 脚本目录 db/migration/（可用 CANGSHU_MIGRATION_DIR 指向副本），脚本只增不改；
#   - 人工发起，应用绝不自动改表；
#   - **改动目标库之前先取迁移锁（键 20260918）与写者锁（键 20260919）**，两把都是非阻塞取锁：
#       迁移锁取不到 → 已有迁移在执行 → 拒绝迁移＋明确提示 → 退出码 2（07 §7「未拿锁＝2」，不写任何字节）；
#       写者锁取不到 → 活跃写者（serve／CLI）在跑 → 拒绝迁移＋提示先停掉 serve 实例 → 退出码 2；
#   - 启动 psql 之前先在宿主侧冻结迁移清单（版本／脚本名／整文件 SHA-256）：一次枚举，之后不再重扫目录；
#   - 拿到两把锁后，在**同一个** psql 会话里先做只读预检：盘上清单与 cangshu_m1.schema_version 台账逐条比对，
#     全部历史校验在任何新增 DDL 之前完成（P0-3① 语义）；
#   - 预检通过后按版本顺序执行**新增**脚本；台账已登记且版本／脚本名／摘要三者一致的脚本只输出 action=skip，
#     不再 cat 给 psql；DDL 与 schema_version 记账同一事务，出错整体回滚；
#   - 预检拒绝＝退出码 1：盘上缺已登记脚本、同版本换名、同版本改字节、台账重复／跳号／多于盘上脚本等，
#     日志带 CANGSHU|migration|preflight-denied|reason=...，不执行任何新增 DDL；
#   - 每个脚本带 script_sha256=<宿主文件 SHA-256>，台账记录的即宿主摘要；
#   - 结尾打印台账并显式释放两把锁；会话若异常结束，PostgreSQL 随会话结束自动释放。
#   - **启动 psql 之前先过目标库名门**（P0-3 收尾补丁）：库名形状（非空／无空白／无通配／小写字母数字下划线）、
#     显式拒绝系统库 postgres／template0／template1，并要求生效传输的 -d 与 CANGSHU_DB_URL 的库名同
#     CANGSHU_DB_NAME 一致；不通过即拒绝（退出码 2），不启动 psql、不写任何字节。
#   - 结尾的锁释放结果按 pg_advisory_unlock 的**实际返回值**打印（released=true|false）：
#     返回 false 说明本会话当时并不持有该锁，迁移仍按成功计数，但收尾会要求人工核查锁的持有者。
#
# 退出码：0 成功；1 迁移失败或预检拒绝（前者脚本报错整体回滚，后者未执行任何新增 DDL）；
#         2 未拿锁（迁移锁或写者锁）或目标库名门拒绝（两者都是「未写任何字节」）。
#
# 交付态（容器内 psql）入口是 scripts/compose-migrate.sh：它只换传输，协议与实现同此（07 §3 两轨一致项②）。

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"
# shellcheck source=lib/migration-lock.sh
. "$ROOT_DIR/scripts/lib/migration-lock.sh"

MIGRATION_DIR="${CANGSHU_MIGRATION_DIR:-db/migration}"
DB_NAME="${CANGSHU_DB_NAME-cangshu}"
DB_USER="${CANGSHU_DB_USER:-postgres}"
DB_HOST="${CANGSHU_DB_HOST:-127.0.0.1}"
DB_PORT="${CANGSHU_DB_PORT:-5432}"
LOG_DIR="${CANGSHU_MIGRATION_LOG_DIR:-$ROOT_DIR/target/migration-lock}"

# 密码只经环境变量传递：不进命令行、不打印。
if [ -n "${CANGSHU_DB_PASSWORD:-}" ]; then
    export PGPASSWORD="$CANGSHU_DB_PASSWORD"
fi

# 传输：默认本机 psql；容器传输由 scripts/compose-migrate.sh 注入（同一协议、同一实现）。
DEFAULT_TRANSPORT="psql -h $DB_HOST -p $DB_PORT -U $DB_USER -d $DB_NAME"
TRANSPORT="${CANGSHU_MIGRATE_PSQL:-$DEFAULT_TRANSPORT}"
read -r -a PSQL_COMMAND <<< "$TRANSPORT"

# 在启动 psql 之前核实生效目标库。库名门拒绝和未拿锁共用退出码 2。
db_name_denied() {
    printf '%s\n' "CANGSHU|migration|denied|reason=db-name-gate|detail=$1" >&2
    printf '%s\n' '目标库名门拒绝：未启动 psql，未执行 DDL。' >&2
    exit "$MIGRATION_EXIT_LOCK_DENIED"
}

transport_db_name() {
    local -a tokens=()
    local i token name=''
    read -r -a tokens <<< "$1"
    for i in "${!tokens[@]}"; do
        token="${tokens[$i]}"
        case "$token" in
            --dbname=*) name="${token#--dbname=}" ;;
            --dbname|-d) name="${tokens[$((i + 1))]:-}" ;;
        esac
    done
    printf '%s' "$name"
}

db_name_from_url() {
    local url="$1"
    if [[ "$url" =~ ^jdbc:postgresql:(//[^/]+/)?([a-z_][a-z0-9_]*)([?;].*)?$ ]]; then
        printf '%s' "${BASH_REMATCH[2]}"
    fi
}

db_name_guard() {
    local candidate="$1" transport_db url_db
    [[ "$candidate" =~ ^[a-z_][a-z0-9_]*$ ]] || db_name_denied '库名必须为小写字母、数字和下划线，且不能以数字开头'
    case "$candidate" in
        postgres|template0|template1) db_name_denied '系统库禁止迁移' ;;
    esac
    transport_db="$(transport_db_name "$TRANSPORT")"
    [ -n "$transport_db" ] || db_name_denied '生效传输没有 -d/--dbname'
    [ "$transport_db" = "$candidate" ] || db_name_denied '生效传输目标与 CANGSHU_DB_NAME 不一致'
    TRANSPORT_DB_NAME="$transport_db"
    URL_DB_NAME=''
    if [ -n "${CANGSHU_DB_URL:-}" ]; then
        url_db="$(db_name_from_url "$CANGSHU_DB_URL")"
        [ -n "$url_db" ] || db_name_denied 'CANGSHU_DB_URL 无法解析库名'
        [ "$url_db" = "$candidate" ] || db_name_denied 'CANGSHU_DB_URL 与 CANGSHU_DB_NAME 不一致'
        URL_DB_NAME="$url_db"
    fi
}

db_name_guard "$DB_NAME"

if [ ! -d "$MIGRATION_DIR" ]; then
    printf '%s\n' "错误：找不到迁移脚本目录 $MIGRATION_DIR" >&2
    exit "$MIGRATION_EXIT_FAILED"
fi
if ! command -v "${PSQL_COMMAND[0]}" >/dev/null 2>&1; then
    printf '%s\n' "错误：找不到 ${PSQL_COMMAND[0]}；把 PostgreSQL 客户端放进 PATH，或用 CANGSHU_MIGRATE_PSQL 指定传输命令" >&2
    exit "$MIGRATION_EXIT_FAILED"
fi

# 清单和摘要在启动 psql 前冻结；台账只读预检使用同一份清单。
if ! migration_manifest_build "$MIGRATION_DIR"; then
    printf '%s\n' '错误：迁移清单冻结失败；未启动 psql。' >&2
    exit "$MIGRATION_EXIT_FAILED"
fi
LAST_VERSION="${MIGRATION_VERSIONS[$((${#MIGRATION_VERSIONS[@]} - 1))]}"

mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/migrate-$(date +%Y%m%d-%H%M%S)-$$.log"

echo "== 人工迁移 → 目标库：$DB_NAME =="
echo "  生效传输：$TRANSPORT"
echo "  目标库名门通过：生效传输 -d=$TRANSPORT_DB_NAME；URL 库名=${URL_DB_NAME:-<未设置>}"
echo "  迁移锁：键 $MIGRATION_LOCK_KEY（非阻塞取锁；取不到＝已有迁移在执行 → 退出码 $MIGRATION_EXIT_LOCK_DENIED）"
echo "  写者锁：键 $WRITER_LOCK_KEY（迁移期间持有；被活跃写者持有 → 拒绝迁移，退出码 $MIGRATION_EXIT_LOCK_DENIED）"
echo "  迁移清单：$MIGRATION_DIR 冻结 ${#MIGRATION_VERSIONS[@]} 个脚本（${MIGRATION_VERSIONS[0]} … $LAST_VERSION）"
echo "  预检：先只读比对台账，全部历史一致后才执行新增 DDL"

set +e
{
    migration_lock_prologue
    migration_driver_stream
    migration_lock_epilogue
} | "${PSQL_COMMAND[@]}" -q -v ON_ERROR_STOP=1 2>&1 | tee "$LOG_FILE"
PSQL_STATUS="${PIPESTATUS[1]}"
set -e

STATUS="$(migration_exit_code "$PSQL_STATUS" "$LOG_FILE")"
if [ "$STATUS" -eq "$MIGRATION_EXIT_OK" ]; then
    LOCK_RELEASE_MARKER="$(grep -o -m 1 'CANGSHU|migration|lock-released[^[:space:]]*' "$LOG_FILE" || true)"
    echo "  会话日志：$LOG_FILE"
    case "$LOCK_RELEASE_MARKER" in
        *'|released=true'*)
            echo "== 迁移完成（两把协议锁已按返回值确认释放：released=true）；应用可以起了 =="
            ;;
        *'|released=false'*)
            echo "== 迁移完成，但两把协议锁的显式释放结果是 released=false（pg_advisory_unlock 返回 false）=="
            echo "  说明：迁移本身成功（DDL 与 schema_version 记账已提交），退出码仍是 $MIGRATION_EXIT_OK ——"
            echo "        07 §7 的退出码 2 只覆盖「没拿到锁」，不覆盖「收尾释放返回 false」（收尾提示不改判定）。"
            echo "  但这是异常信号：本会话当时并未持有它声称持有的锁，可能已被会话内某段 SQL 解掉。"
            echo "  请人工核查锁的持有者：SELECT locktype, objid, pid FROM pg_locks WHERE locktype='advisory'。"
            ;;
        *)
            echo "== 迁移完成，但会话日志里没有锁释放标记（见 $LOG_FILE）=="
            echo "  说明：正常路径会打印 $MIGRATION_RELEASED_MARKER；缺失时请核查会话日志与两把协议锁的状态。"
            ;;
    esac
    exit "$MIGRATION_EXIT_OK"
fi

if [ "$STATUS" -eq "$MIGRATION_EXIT_LOCK_DENIED" ]; then
    REASON="$(migration_denied_reason "$LOG_FILE")"
    echo "  迁移被拒绝：${REASON:-未拿到协议锁}"
    echo "  说明：未执行任何 DDL，未写任何字节。"
    case "$REASON" in
        *migration-lock*)
            echo "  原因：已有迁移在执行（迁移锁 $MIGRATION_LOCK_KEY 被持有）。等它结束，或确认没有迁移任务后重试。"
            ;;
        *writer-lock*)
            echo "  原因：写者锁 $WRITER_LOCK_KEY 被活跃写者持有（serve／CLI 实例在跑）。"
            echo "  指引：请先停掉 serve 实例——07 §1 要求「迁移操作需确保业务写者已退出」——确认写者退出后重试。"
            ;;
        *)
            echo "  原因：未拿到协议锁，详见会话日志。"
            ;;
    esac
    echo "  会话日志：$LOG_FILE"
    echo "  退出码 $MIGRATION_EXIT_LOCK_DENIED（07-运行手册 §7：未拿到 DB 会话锁 → 停写，退出码 2，不写任何字节）"
    exit "$MIGRATION_EXIT_LOCK_DENIED"
fi

if grep -q "${MIGRATION_PREFLIGHT_MARKER}|preflight-denied" "$LOG_FILE" 2>/dev/null; then
    REASON="$(grep -o -m 1 "${MIGRATION_PREFLIGHT_MARKER}|preflight-denied|reason=[A-Za-z-]*" "$LOG_FILE" || true)"
    echo "  预检拒绝：${REASON:-台账与盘上迁移脚本不一致}"
    echo "  说明：只读预检在新增 DDL 之前完成，本次未执行任何新增 DDL、未写任何字节。"
    echo "  修复口径：恢复正确的旧脚本／台账，或新增更高版本；禁止改已发布 SQL、删台账或清库绕过（ADR-0001 §七 ^dec-t3）。"
    echo "  会话日志：$LOG_FILE"
    exit "$MIGRATION_EXIT_FAILED"
fi

echo "  迁移失败：psql 退出码 $PSQL_STATUS；DDL 与 schema_version 记账在同一事务内，出错整体回滚，失败脚本无残留。"
echo "  会话日志：$LOG_FILE"
exit "$MIGRATION_EXIT_FAILED"
