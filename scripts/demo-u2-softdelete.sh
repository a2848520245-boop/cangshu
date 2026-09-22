#!/usr/bin/env bash
# 仓鼠 M1 真实 HTTP 演示与自检（任务 6 · 删除资源＝软删进回收站）
#
# 用法：
#   bash scripts/demo-u2-softdelete.sh [端口]
#
# 前置：与 scripts/demo-u1-revival.sh 相同（JAVA_HOME 指向 JDK 21 + Maven + 本机 PostgreSQL 17）。
#   运行时：用 ${JAVA_HOME}/bin/java[.exe] 的绝对路径起 serve，并在建库前断言主版本 21；不符即以
#   CANGSHU|demo|java21|denied 可见失败（退出码 3）——裸 java 不用（本机 PATH 上是 Java 8）。
#   本脚本**自行重建**演示库（默认 cangshu_u2demo），迁移统一走人工迁移入口 bash scripts/migrate.sh
#   （07 §4：迁移锁 → 写者锁 → 只读预检 → 跳过已登记版本 → 仅执行新增脚本；退出码 0／1／2）。
#
# 本脚本演示并自检的是任务 6 的验收面（05-接口契约 §3.5、04-架构与计划 §5 ①、
# 06-数据契约 §7／§8）：
#   ① DELETE /api/resources/{id} → 204（无响应体）；
#   ② 软删＝写 deletedAt／expireAt 进回收站：行还在、两个时间戳齐备、到期时刻＝软删时刻＋保留期；
#   ③ 删除**只删引用**：内容行仍 READY、位置行与物理字节都在，软删不触发内容待回收；
#   ④ 回收站行**计入保护引用计数**（06 §8）；
#   ⑤ 回收站资源对普通列表／详情／下载三处都不可见；
#   ⑥ 重复软删幂等：仍 204，且首次软删时刻与到期时刻都不被刷新；
#   ⑦ 负例：未知 UUID／已硬删 → 404 RESOURCE_NOT_FOUND；非 UUID → 400 INVALID_ARGUMENT；
#   ⑧ 文件树快照（ACC-G5 的证据形态之一）：软删前后、以及硬删行后，内容地址上的字节清单完全一致。
#
# 产出：逐项请求／SQL 观测与结论表。退出码：0＝全部符合预期；1＝有项不符（自检失败）。
# 说明：本脚本是「演示与交付」材料，**不是** 08-验收规范 §2 的验收证据本身。

set -uo pipefail

PORT="${1:-18082}"
BASE="http://127.0.0.1:${PORT}"
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
JAR="${ROOT_DIR}/target/cangshu-0.1.0-SNAPSHOT.jar"
DATA_ROOT="${CANGSHU_U2_DEMO_DATA_ROOT:-${ROOT_DIR}/target/demo-u2-data-root}"
LOG_DIR="${CANGSHU_U2_DEMO_LOG_DIR:-${ROOT_DIR}/target/demo-u2-logs}"
RUN_LOG="${LOG_DIR}/demo-u2-serve.log"
DB="${CANGSHU_U2_DEMO_DB-cangshu_u2demo}"
PSQL="${PSQL:-E:/PostgreSQL/17/bin/psql.exe}"
MIGRATION_DIR="${ROOT_DIR}/db/migration"

export PGPASSWORD="${CANGSHU_DB_PASSWORD:-postgres}"
export CANGSHU_DB_URL="${CANGSHU_DB_URL-jdbc:postgresql://127.0.0.1:5432/${DB}?currentSchema=cangshu_m1}"
export CANGSHU_DB_USER="${CANGSHU_DB_USER:-postgres}"

db_name_guard() {
  [ "$DB" = 'cangshu_u2demo' ] || { printf '%s\n' '[库名安全门] U2 只允许 cangshu_u2demo；未执行删除或 DDL。' >&2; exit 2; }
  local url_db="${CANGSHU_DB_URL##*/}"
  url_db="${url_db%%\?*}"
  [ "$url_db" = "$DB" ] || { printf '%s\n' '[库名安全门] URL 目标库与 U2 演示库不一致；未执行删除或 DDL。' >&2; exit 2; }
}
db_name_guard

if [ -z "${CANGSHU_U2_DEMO_LOG_DIR+x}" ]; then
  [ -f "${ROOT_DIR}/pom.xml" ] && [ "${LOG_DIR}" = "${ROOT_DIR}/target/demo-u2-logs" ] \
    || { printf '%s\n' '拒绝清理：U2 日志目录不在默认白名单内。' >&2; exit 2; }
  rm -rf -- "${LOG_DIR}"
fi
# 数据根每次重建（仅默认值，避免误删用户显式指定的目录），否则前次运行的字节会残留下来，
# 污染 ACC-G5 的文件树快照——快照本该是「本次上传的那一份内容」的干净清单。
if [ -z "${CANGSHU_U2_DEMO_DATA_ROOT+x}" ]; then
  [ -f "${ROOT_DIR}/pom.xml" ] && [ "${DATA_ROOT}" = "${ROOT_DIR}/target/demo-u2-data-root" ] \
    || { printf '%s\n' '拒绝清理：U2 数据根不在默认白名单内。' >&2; exit 2; }
  rm -rf -- "${DATA_ROOT}"
fi
mkdir -p "${LOG_DIR}" "${DATA_ROOT}"
PASS=0
FAIL=0
LAST_BODY=""
SUMMARY="${LOG_DIR}/demo-u2-summary.txt"
: > "${SUMMARY}"

say() { printf '%s\n' "$*" | tee -a "${SUMMARY}"; }

win_path() {
  if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s' "$1"; fi
}

check() { # <实际> <期望> <说明>
  if [ "$1" = "$2" ]; then
    PASS=$((PASS + 1)); say "  [OK]   $3 → $1（期望 $2）"
  else
    FAIL=$((FAIL + 1)); say "  [FAIL] $3 → $1（期望 $2）"
  fi
}

hit() { # <期望状态> <说明> <curl 参数...>
  local expect="$1"; shift
  local label="$1"; shift
  local body_file="${LOG_DIR}/body-$(echo "${label}" | tr -c 'A-Za-z0-9' '_').out"
  local status
  status="$(curl -sS -o "$(win_path "${body_file}")" -w '%{http_code}' "$@" || echo 000)"
  check "${status}" "${expect}" "${label}"
  if [ "${status}" != "${expect}" ]; then
    say "         body: $(head -c 300 "${body_file}" 2>/dev/null)"
  fi
  LAST_BODY="${body_file}"
}

json_str() { sed -n "s/.*\"$1\":\"\([^\"]*\)\".*/\1/p" "$2" | head -1; }

# q <sql>：结构化取单值（-tA 去表头与对齐，去掉空白）
q() { "${PSQL}" -h 127.0.0.1 -U "${CANGSHU_DB_USER}" -d "${DB}" -tAc "$1" 2>/dev/null | tr -d '[:space:]'; }
blob_path() { printf '%s/sha256/%s/%s/%s' "${DATA_ROOT}" "${1:0:2}" "${1:2:2}" "${1}"; }

# 文件树快照（ACC-G5 的证据形态之一）：内容地址上的相对键清单，排除临时区（临时文件属上传期现象）
filetree_snapshot() { # <名称> → 写出并回显路径
  local out="${LOG_DIR}/filetree-$1.txt"
  find "${DATA_ROOT}" -type f -not -path '*/tmp/*' 2>/dev/null \
    | sed "s|^${DATA_ROOT}/||" | sort > "${out}"
  printf '%s' "${out}"
}
same_filetree() { # <快照1> <快照2>
  if diff -q "$1" "$2" >/dev/null 2>&1; then printf 'same'; else printf 'different'; fi
}

# ─────────────────────── P0-3② 共用件（与 u1／u3 同形） ───────────────────────
JAVA_BIN=""

unix_path() { # Windows 形态（E:\...）→ POSIX（/e/...）；已是 POSIX 则原样返回
  case "$1" in
    [A-Za-z]:[\\/]*) if command -v cygpath >/dev/null 2>&1; then cygpath -u "$1"; else printf '%s' "$1"; fi ;;
    *) printf '%s' "$1" ;;
  esac
}

java21_deny() { # <原因>：可见失败（退出码 3），不发 DDL、不起进程
  printf '%s\n' "CANGSHU|demo|java21|denied|reason=$1|JAVA_HOME=${JAVA_HOME:-<未设置>}" >&2
  printf '%s\n' "  说明：三个 demo 脚本统一强制 JDK 21（07 §1 运行时）；本机 PATH 上的 java 是 Java 8，裸 java 起不了 serve。" >&2
  printf '%s\n' "  修复：export JAVA_HOME=<JDK 21 安装目录>（Windows 形态或 /e/... 都可以）后重跑本脚本；本脚本未发出任何 DDL、未启动进程。" >&2
  exit 3
}

require_java21() { # 建库／构建／启动之前：JAVA_HOME → bin/java[.exe]，断言主版本 21
  local home="${JAVA_HOME:-}" posix_home="" candidate="" version_line=""
  [ -n "$home" ] || java21_deny "JAVA_HOME-unset"
  posix_home="$(unix_path "$home")"
  [ -d "$posix_home" ] || java21_deny "JAVA_HOME-dir-missing:$posix_home"
  for candidate in "$posix_home/bin/java.exe" "$posix_home/bin/java"; do
    if [ -x "$candidate" ]; then JAVA_BIN="$candidate"; break; fi
  done
  [ -n "$JAVA_BIN" ] || java21_deny "java-executable-missing:$posix_home/bin"
  version_line="$("${JAVA_BIN}" -version 2>&1 | head -1)"
  case "$version_line" in
    *'version "21.'*) ;;
    *) java21_deny "not-jdk21:$version_line" ;;
  esac
  export JAVA_HOME="$posix_home"   # 构建（mvn 脚本）与子进程共用同一 JDK，不回落 PATH
  say "CANGSHU|demo|java21|ok|javaBin=$(win_path "$JAVA_BIN")|version=$version_line"
}

wait_log_line() { # <日志文件> <ERE> <超时秒>
  local log="$1" pattern="$2" timeout="${3:-30}" waited=0
  while [ "$waited" -lt "$timeout" ]; do
    if grep -Eq "$pattern" "$log" 2>/dev/null; then return 0; fi
    sleep 1; waited=$((waited + 1))
  done
  return 1
}

start_server() { # <serve 日志> <阶段说明>：JDK 21 起 serve；等健康端点＋写者门＋启动维护摘要
  local log="$1" phase="$2" ready=0
  : > "$log"
  "${JAVA_BIN}" -jar "$(win_path "${JAR}")" --server.port="${PORT}" \
    --cangshu.data-root="$(win_path "${DATA_ROOT}")" >> "$log" 2>&1 &
  SERVER_PID=$!
  for _ in $(seq 1 60); do
    if curl -sS -o "$(win_path "${LOG_DIR}/body-health.out")" "${BASE}/actuator/health" 2>/dev/null; then ready=1; break; fi
    sleep 1
  done
  if [ "$ready" -ne 1 ]; then
    say "serve 在 60 秒内未就绪（$phase）—— 演示中止。serve 日志尾部："
    tail -20 "$log" | tee -a "${SUMMARY}"
    exit 1
  fi
  if ! wait_log_line "$log" 'CANGSHU[|]writer-gate[|]acquired' 30; then
    say "serve 日志没有写者门获取记录（$phase）—— 演示中止，日志：$log"
    exit 1
  fi
  if ! wait_log_line "$log" 'CANGSHU[|]job[|]maintenance[|]' 30; then
    say "serve 日志没有启动维护摘要（$phase）—— 演示中止。serve 日志尾部："
    tail -20 "$log" | tee -a "${SUMMARY}"
    exit 1
  fi
  say "  serve 就绪（pid $SERVER_PID，$phase）"
  say "  $(grep -o 'CANGSHU|writer-gate|acquired.*' "$log" | tail -1)"
  say "  $(grep -o 'CANGSHU|job|maintenance|.*' "$log" | tail -1)"
}

run_migration() { # 统一迁移入口（设计 §2）：不再内联 psql -f；密码只经 PGPASSWORD 环境变量
  local mig_log_dir="${LOG_DIR}/migration" session_log="" status=0 line=""
  mkdir -p "$mig_log_dir"
  CANGSHU_DB_NAME="${DB}" CANGSHU_MIGRATION_DIR="${MIGRATION_DIR}" \
  CANGSHU_MIGRATION_LOG_DIR="$mig_log_dir" \
  CANGSHU_MIGRATE_PSQL="${PSQL} -h 127.0.0.1 -p 5432 -U ${CANGSHU_DB_USER} -d ${DB}" \
    bash "${ROOT_DIR}/scripts/migrate.sh" >> "${SUMMARY}" 2>&1
  status=$?
  if [ "$status" -ne 0 ]; then
    say "  迁移入口 scripts/migrate.sh 退出码 $status（0 成功／1 迁移失败或预检拒绝／2 未拿锁）；未启动 serve，完整输出见 ${SUMMARY}"
    exit 1
  fi
  session_log="$(ls -1t "$mig_log_dir"/migrate-*.log 2>/dev/null | head -1)"
  say "  迁移入口：bash scripts/migrate.sh → 退出码 0（迁移锁＋写者锁已在其会话内释放）"
  say "  迁移会话日志：${session_log:-<未找到>}"
  if [ -n "$session_log" ]; then
    while IFS= read -r line; do say "    $line"; done \
      < <(grep -E 'CANGSHU[|]migration[|](script|ledger|lock-acquired|lock-released)' "$session_log")
  fi
}

cleanup() {
  if [ -n "${SERVER_PID:-}" ] && kill -0 "${SERVER_PID}" 2>/dev/null; then
    kill "${SERVER_PID}" 2>/dev/null
    wait "${SERVER_PID}" 2>/dev/null
    say "  已在演示结束后停止 serve 进程（pid ${SERVER_PID}）"
  fi
}
trap cleanup EXIT

say "== 仓鼠 M1 真实 HTTP 演示（任务 6 · 删除资源＝软删进回收站）=="
say "时间：$(date '+%Y-%m-%dT%H:%M:%S%z')"
say "仓（提交）：$(cd "${ROOT_DIR}" && git rev-parse HEAD 2>/dev/null || echo '不可观测')"
say "工作树改动数：$(cd "${ROOT_DIR}" && git status --porcelain=v1 --untracked-files=all 2>/dev/null | wc -l | tr -d ' ')"
say "JDBC：${CANGSHU_DB_URL}"
say "数据根：$(win_path "${DATA_ROOT}")"
say ""

if [ "${CANGSHU_U2_DEMO_SKIP_BUILD:-0}" = "1" ]; then
  say "跳过构建（CANGSHU_U2_DEMO_SKIP_BUILD=1）；使用现有产物：${JAR}"
  [ -f "${JAR}" ] || { say "产物不存在：${JAR}"; exit 1; }
else
  say "构建产物：${MVN_CMD:-mvn} -B -ntp -Dmaven.repo.local=var/m2repo -DskipTests package"
  ( cd "${ROOT_DIR}" && "${MVN_CMD:-mvn}" -B -ntp -Dmaven.repo.local=var/m2repo -DskipTests package ) \
    >> "${SUMMARY}" 2>&1 || { say "构建失败，见 ${SUMMARY}"; exit 1; }
  [ -f "${JAR}" ] || { say "构建未产出 ${JAR}"; exit 1; }
fi

say "-- 建库与人工迁移（07 §4：脚本只增不改，DDL 与 schema_version 记账同一事务）--"
"${PSQL}" -h 127.0.0.1 -U "${CANGSHU_DB_USER}" -d postgres -c "DROP DATABASE IF EXISTS ${DB}" >> "${SUMMARY}" 2>&1
"${PSQL}" -h 127.0.0.1 -U "${CANGSHU_DB_USER}" -d postgres -c "CREATE DATABASE ${DB}" >> "${SUMMARY}" 2>&1 \
  || { say "建库失败（psql=${PSQL}）"; exit 1; }
for script in "${MIGRATION_DIR}"/V*.sql; do
  script_sha="$(sha256sum "${script}" | cut -d' ' -f1)"
  "${PSQL}" -h 127.0.0.1 -U "${CANGSHU_DB_USER}" -d "${DB}" -q -v ON_ERROR_STOP=1 \
    -v "script_sha256=${script_sha}" -f "$(win_path "${script}")" >> "${SUMMARY}" 2>&1 \
    || { say "迁移失败：${script}"; exit 1; }
  say "  已执行 $(basename "${script}")（sha256=${script_sha:0:12}…）"
done
say "  台账：$(q "SELECT string_agg(version || ':' || script_name, ', ' ORDER BY version) FROM cangshu_m1.schema_version")"

say ""
say "启动 serve：java -jar <jar> --server.port=${PORT}"
java -jar "$(win_path "${JAR}")" --server.port="${PORT}" \
  --cangshu.data-root="$(win_path "${DATA_ROOT}")" > "${RUN_LOG}" 2>&1 &
SERVER_PID=$!

READY=0
for _ in $(seq 1 60); do
  if curl -sS -o "$(win_path "${LOG_DIR}/body-health.out")" "${BASE}/actuator/health" 2>/dev/null; then READY=1; break; fi
  sleep 1
done
if [ "${READY}" -ne 1 ]; then
  say "serve 在 60 秒内未就绪 —— 演示中止。serve 日志尾部："
  tail -20 "${RUN_LOG}" | tee -a "${SUMMARY}"
  exit 1
fi
say "  serve 就绪（pid ${SERVER_PID}）"

say ""
say "-- ① 准备：同一内容上传两条资源（A 待删、B 保留）--"
SAMPLE="${LOG_DIR}/u2-sample.txt"
printf '仓鼠 U2 软删演示样本 %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" > "${SAMPLE}"
SAMPLE_WIN="$(win_path "${SAMPLE}")"
hit 201 "POST /api/resources（副本一）" \
  -F "file=@${SAMPLE_WIN};type=text/plain;filename=U2副本一.txt" "${BASE}/api/resources"
RES_A="$(json_str id "${LAST_BODY}")"
CONTENT_ID="$(json_str contentId "${LAST_BODY}")"
DIGEST="$(json_str digest "${LAST_BODY}")"
BLOB="$(blob_path "${DIGEST}")"
hit 201 "POST /api/resources（副本二，同内容）" \
  -F "file=@${SAMPLE_WIN};type=text/plain;filename=U2副本二.txt" "${BASE}/api/resources"
RES_B="$(json_str id "${LAST_BODY}")"
say "  A=${RES_A}（待删）  B=${RES_B}（保留）  contentId=${CONTENT_ID}"
check "$(q "SELECT count(*) FROM cangshu_m1.resource WHERE content_id = '${CONTENT_ID}'")" "2" "保护引用数（软删前）"
check "$(q "SELECT status FROM cangshu_m1.content WHERE id = '${CONTENT_ID}'")" "READY" "内容态（软删前）"
TREE_BEFORE="$(filetree_snapshot before-softdelete)"

say ""
say "-- ② DELETE A → 204：写 deletedAt／expireAt 进回收站（无响应体）--"
DEL_BODY="${LOG_DIR}/body-delete-a.out"
DEL_STATUS="$(curl -sS -o "$(win_path "${DEL_BODY}")" -w '%{http_code}' -X DELETE "${BASE}/api/resources/${RES_A}" || echo 000)"
check "${DEL_STATUS}" "204" "DELETE /api/resources/{A}"
check "$(wc -c < "${DEL_BODY}" | tr -d ' ')" "0" "204 无响应体"
check "$(q "SELECT status FROM cangshu_m1.resource WHERE id = '${RES_A}'")" "DELETED" "资源行已置删除态"
check "$(q "SELECT (deleted_at IS NOT NULL AND expire_at IS NOT NULL)::text FROM cangshu_m1.resource WHERE id = '${RES_A}'")" \
  "true" "软删时刻与固定到期时刻齐备（ck_resource_softdelete）"
check "$(q "SELECT extract(epoch from (expire_at - deleted_at))::int FROM cangshu_m1.resource WHERE id = '${RES_A}'")" \
  "604800" "到期时刻＝软删时刻＋保留期（默认 7 天＝604800 秒，06 §8）"

say ""
say "-- ③ 删除只删引用：内容与字节不动，软删不触发待回收 --"
check "$(q "SELECT status FROM cangshu_m1.content WHERE id = '${CONTENT_ID}'")" "READY" "内容仍就绪（未被软删推动）"
check "$(q "SELECT count(*) FROM cangshu_m1.location WHERE content_id = '${CONTENT_ID}'")" "1" "位置行未动"
check "$([ -f "${BLOB}" ] && echo yes || echo no)" "yes" "物理字节未动（字节只由 GC 删）"
check "$(q "SELECT count(*) FROM cangshu_m1.resource WHERE content_id = '${CONTENT_ID}'")" "2" "回收站行计入保护引用计数（A＋B＝2）"

say ""
say "-- ④ 回收站资源对普通列表／详情／下载三处不可见 --"
hit 200 "GET /api/resources?page=1&size=20" "${BASE}/api/resources?page=1&size=20"
check "$(grep -c "${RES_A}" "${LAST_BODY}" || true)" "0" "普通列表不含已软删资源"
check "$(sed -n 's/.*"total":\([0-9]*\).*/\1/p' "${LAST_BODY}" | head -1)" "1" "普通列表 total 只计活跃资源"
hit 404 "GET /api/resources/{A}（详情）" "${BASE}/api/resources/${RES_A}"
check "$(json_str code "${LAST_BODY}")" "RESOURCE_NOT_FOUND" "详情错误码"
hit 404 "GET /api/resources/{A}/content（下载／预览）" "${BASE}/api/resources/${RES_A}/content"
hit 200 "GET /api/resources/{B}（另一条引用照常可读）" "${BASE}/api/resources/${RES_B}"

say ""
say "-- ⑤ 重复软删幂等：仍 204，且首次软删时刻与到期时刻都不刷新（06 §8）--"
FIRST_DELETED_AT="$(q "SELECT deleted_at FROM cangshu_m1.resource WHERE id = '${RES_A}'")"
FIRST_EXPIRE_AT="$(q "SELECT expire_at FROM cangshu_m1.resource WHERE id = '${RES_A}'")"
hit 204 "DELETE /api/resources/{A}（第二次）" -X DELETE "${BASE}/api/resources/${RES_A}"
check "$(q "SELECT deleted_at FROM cangshu_m1.resource WHERE id = '${RES_A}'")" "${FIRST_DELETED_AT}" \
  "首次软删时刻未被刷新"
check "$(q "SELECT expire_at FROM cangshu_m1.resource WHERE id = '${RES_A}'")" "${FIRST_EXPIRE_AT}" \
  "保留期未被反复删除无限延长"

say ""
say "-- ⑥ 再软删 B：两条都在回收站，内容仍不进待回收（软删不归零）--"
hit 204 "DELETE /api/resources/{B}" -X DELETE "${BASE}/api/resources/${RES_B}"
check "$(q "SELECT count(*) FROM cangshu_m1.resource WHERE content_id = '${CONTENT_ID}'")" "2" "保护引用数仍为 2（都在回收站里）"
check "$(q "SELECT status FROM cangshu_m1.content WHERE id = '${CONTENT_ID}'")" "READY" "内容仍就绪"
check "$([ -f "${BLOB}" ] && echo yes || echo no)" "yes" "字节仍在"
TREE_AFTER="$(filetree_snapshot after-softdelete)"
check "$(same_filetree "${TREE_BEFORE}" "${TREE_AFTER}")" "same" \
  "文件树快照：两条资源都软删后，内容地址上的字节清单与软删前完全一致"

say ""
say "-- ⑦ 归零语义的触发点（硬删／到期／清空属任务 28，本轮不含端点）--"
"${PSQL}" -h 127.0.0.1 -U "${CANGSHU_DB_USER}" -d "${DB}" -q \
  -c "DELETE FROM cangshu_m1.resource WHERE content_id='${CONTENT_ID}'" >> "${SUMMARY}" 2>&1
check "$(q "SELECT count(*) FROM cangshu_m1.resource WHERE content_id = '${CONTENT_ID}'")" "0" "保护引用数（硬删行后）＝0"
TREE_AFTER_HARD_DELETE="$(filetree_snapshot after-harddelete-rows)"
check "$(same_filetree "${TREE_AFTER}" "${TREE_AFTER_HARD_DELETE}")" "same" \
  "文件树快照：删掉最后一行（引用归零）也不删字节——字节只由 GC 删（04 §5 ③）"
say "  说明：引用归零后置 RECLAIM_PENDING 的跃迁由 ProtectionReferenceService 在同锁事务内完成（任务 26 已落地语义，"
say "        挂载点为任务 28 的硬删／清空路径）；本演示不代替该端到端路径，任务 28 完成后须补。"

say ""
say "-- ⑧ 负例 --"
hit 404 "DELETE /api/resources/{A}（行已在 ⑦ 硬删 → 404，契约 §3.5）" -X DELETE "${BASE}/api/resources/${RES_A}"
check "$(json_str code "${LAST_BODY}")" "RESOURCE_NOT_FOUND" "错误码"
hit 404 "DELETE /api/resources/{未知 UUID}" -X DELETE "${BASE}/api/resources/00000000-0000-7000-8000-000000000000"
check "$(json_str code "${LAST_BODY}")" "RESOURCE_NOT_FOUND" "错误码"
hit 400 "DELETE /api/resources/not-a-uuid（非 UUID）" -X DELETE "${BASE}/api/resources/not-a-uuid"
check "$(json_str code "${LAST_BODY}")" "INVALID_ARGUMENT" "错误码"

say ""
say "== 汇总：通过 ${PASS} ｜ 不符 ${FAIL} =="
say "serve 日志：${RUN_LOG}"
say "结构化摘要：${SUMMARY}"
if [ "${FAIL}" -ne 0 ]; then
  say "结论：有观测项与任务 6 的契约预期不符，需排查（见上方 [FAIL]）。"
  exit 1
fi
say "结论：DELETE → 204 软删（写 deletedAt／expireAt）、只删引用（内容与字节不动、回收站行仍计入保护引用）、"
say "      列表／详情／下载三处不可见、重复软删幂等、负例 404／400 —— 各项与 05 §3.5、04 §5 ①、06 §7／§8 一致。"
