#!/usr/bin/env bash
# 仓鼠 M1 真实 HTTP 演示与自检（任务 28 · 回收站三端点 ＋ GC 三段提交 ＋ 每日对账三类）
#
# 用法：
#   bash scripts/demo-u3-trash-gc.sh [端口]
#
# 前置：与 scripts/demo-u2-softdelete.sh 相同（JAVA_HOME 指向 JDK 21 + Maven + 本机 PostgreSQL 17）。
#   运行时：serve 与 CLI 一次性作业都用 ${JAVA_HOME}/bin/java[.exe] 的绝对路径，建库前断言主版本 21；
#   不符即以 CANGSHU|demo|java21|denied 可见失败（退出码 3）——裸 java 不用（本机 PATH 上是 Java 8）。
#   本脚本**自行重建**演示库（默认 cangshu_u3demo）与数据根，迁移统一走人工迁移入口 bash scripts/migrate.sh。
#   生命周期（P0-3②）：serve 停写且写者门释放之后才允许跑 CLI 作业（GC／对账）；异常夹具只能在最后一次
#   启动维护之后布置，避免重启维护把待测状态提前消费（见 ⑦／⑧／⑨）。
#
# 覆盖（05-接口契约 §3.6–§3.8、04-架构与计划 §5 ②③④、07-运行手册 §6、08-验收规范 §4／§5）：
#   ① 回收站列表：只给已软删未到期的行、另带 deletedAt／expireAt、不出现在普通列表；
#   ② 回收站分页与 §3.2 同口径：size>200／size=0／page=0 → 400；
#   ③ 还原：200 回活跃列表，库里两个时间戳真正置空；
#   ④ 清空负例：缺 confirm／confirm=false → 400 且一行不删（08 §5）；
#   ⑤ 清空正例：200 {deletedCount}，删行、引用归零的内容进待回收，位置行与字节仍在；
#   ⑥ GC 一次性作业（CLI `--mode=gc`）：到期行硬删 ＋ 回收队列三段提交 → 内容已回收、位置行与字节消失；
#   ⑦ 对账一次性作业（CLI `--mode=reconcile`）：孤儿字节隔离、缺失字节告警，**退出码 4**（07 §6 非零结果）。
#
# 产出：逐项请求／SQL 观测与结论表。退出码：0＝全部符合预期；1＝有项不符（自检失败）。
# 说明：本脚本是「演示与交付」材料，**不是** 08-验收规范 §2 的验收证据本身。

set -uo pipefail

PORT="${1:-18083}"
BASE="http://127.0.0.1:${PORT}"
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
JAR="${ROOT_DIR}/target/cangshu-0.1.0-SNAPSHOT.jar"
DATA_ROOT="${CANGSHU_U3_DEMO_DATA_ROOT:-${ROOT_DIR}/target/demo-u3-data-root}"
LOG_DIR="${CANGSHU_U3_DEMO_LOG_DIR:-${ROOT_DIR}/target/demo-u3-logs}"
RUN_LOG="${LOG_DIR}/demo-u3-serve.log"
DB="${CANGSHU_U3_DEMO_DB-cangshu_u3demo}"
PSQL="${PSQL:-E:/PostgreSQL/17/bin/psql.exe}"
MIGRATION_DIR="${ROOT_DIR}/db/migration"

export PGPASSWORD="${CANGSHU_DB_PASSWORD:-postgres}"
export CANGSHU_DB_URL="${CANGSHU_DB_URL-jdbc:postgresql://127.0.0.1:5432/${DB}?currentSchema=cangshu_m1}"
export CANGSHU_DB_USER="${CANGSHU_DB_USER:-postgres}"

db_name_guard() {
  [ "$DB" = 'cangshu_u3demo' ] || { printf '%s\n' '[库名安全门] U3 只允许 cangshu_u3demo；未执行删除或 DDL。' >&2; exit 2; }
  local url_db="${CANGSHU_DB_URL##*/}"
  url_db="${url_db%%\?*}"
  [ "$url_db" = "$DB" ] || { printf '%s\n' '[库名安全门] URL 目标库与 U3 演示库不一致；未执行删除或 DDL。' >&2; exit 2; }
}
db_name_guard

if [ -z "${CANGSHU_U3_DEMO_LOG_DIR+x}" ]; then
  [ -f "${ROOT_DIR}/pom.xml" ] && [ "${LOG_DIR}" = "${ROOT_DIR}/target/demo-u3-logs" ] \
    || { printf '%s\n' '拒绝清理：U3 日志目录不在默认白名单内。' >&2; exit 2; }
  rm -rf -- "${LOG_DIR}"
fi
if [ -z "${CANGSHU_U3_DEMO_DATA_ROOT+x}" ]; then
  [ -f "${ROOT_DIR}/pom.xml" ] && [ "${DATA_ROOT}" = "${ROOT_DIR}/target/demo-u3-data-root" ] \
    || { printf '%s\n' '拒绝清理：U3 数据根不在默认白名单内。' >&2; exit 2; }
  rm -rf -- "${DATA_ROOT}"     # 默认数据根每次重建，快照才干净；显式指定时不越权删
fi
mkdir -p "${LOG_DIR}" "${DATA_ROOT}"
PASS=0
FAIL=0
LAST_BODY=""
SUMMARY="${LOG_DIR}/demo-u3-summary.txt"
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
json_num() { sed -n "s/.*\"$1\":\([0-9-]*\).*/\1/p" "$2" | head -1; }

q() { "${PSQL}" -h 127.0.0.1 -U "${CANGSHU_DB_USER}" -d "${DB}" -tAc "$1" 2>/dev/null | tr -d '[:space:]'; }
blob_path() { printf '%s/sha256/%s/%s/%s' "${DATA_ROOT}" "${1:0:2}" "${1:2:2}" "${1}"; }

# CLI 一次性作业（07 §2：默认不启 HTTP 容器）：输出结构化摘要，退出码即判定。
# 注意：作业**不能**在命令替换里调用——命令替换开子壳，退出码拿不到，$? 会变成后面 grep 的退出码
# （那会把「需人工介入 → 非零」的判定悄悄变成假通过）。故此处拆成「执行」与「取摘要」两步。
run_job() { # <mode> <输出文件>；退出码写入全局 JOB_EXIT
  local mode="$1" out="$2"
  java -jar "$(win_path "${JAR}")" --spring.main.web-application-type=none \
    --cangshu.data-root="$(win_path "${DATA_ROOT}")" --mode="${mode}" > "${out}" 2>&1
  JOB_EXIT=$?
}
job_summary() { # <输出文件> → 结构化摘要单行
  grep -E "^(gc|reconcile)\|" "$1" | tail -1
}

cleanup() {
  if [ -n "${SERVER_PID:-}" ] && kill -0 "${SERVER_PID}" 2>/dev/null; then
    kill "${SERVER_PID}" 2>/dev/null
    wait "${SERVER_PID}" 2>/dev/null
    say "  已在演示结束后停止 serve 进程（pid ${SERVER_PID}）"
  fi
}
trap cleanup EXIT

say "== 仓鼠 M1 真实 HTTP 演示（任务 28 · 回收站与 GC）=="
say "时间：$(date '+%Y-%m-%dT%H:%M:%S%z')"
say "仓（提交）：$(cd "${ROOT_DIR}" && git rev-parse HEAD 2>/dev/null || echo '不可观测')"
say "工作树改动数：$(cd "${ROOT_DIR}" && git status --porcelain=v1 --untracked-files=all 2>/dev/null | wc -l | tr -d ' ')"
say "JDBC：${CANGSHU_DB_URL}"
say "数据根：$(win_path "${DATA_ROOT}")"
say ""

if [ "${CANGSHU_U3_DEMO_SKIP_BUILD:-0}" = "1" ]; then
  say "跳过构建（CANGSHU_U3_DEMO_SKIP_BUILD=1）；使用现有产物：${JAR}"
  [ -f "${JAR}" ] || { say "产物不存在：${JAR}"; exit 1; }
else
  say "构建产物：${MVN_CMD:-mvn} -B -ntp -Dmaven.repo.local=var/m2repo -DskipTests package"
  ( cd "${ROOT_DIR}" && "${MVN_CMD:-mvn}" -B -ntp -Dmaven.repo.local=var/m2repo -DskipTests package ) \
    >> "${SUMMARY}" 2>&1 || { say "构建失败，见 ${SUMMARY}"; exit 1; }
  [ -f "${JAR}" ] || { say "构建未产出 ${JAR}"; exit 1; }
fi

say "-- 建库与人工迁移（07 §4）--"
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
say "  启动对账先于服务（04 §8 步骤 3）：$(grep -oE 'reconcile\|[^ ]*needsAttention=[a-z]*' "${RUN_LOG}" | tail -1)"

say ""
say "-- ① 准备：上传两条不同内容的资源（A 待删、B 保留）--"
SAMPLE_A="${LOG_DIR}/u3-a.txt"; SAMPLE_B="${LOG_DIR}/u3-b.txt"
printf '仓鼠 U3 回收站样本 A %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" > "${SAMPLE_A}"
printf '仓鼠 U3 回收站样本 B %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" > "${SAMPLE_B}"
hit 201 "POST /api/resources（A）" -F "file=@$(win_path "${SAMPLE_A}");type=text/plain;filename=U3-A.txt" "${BASE}/api/resources"
RES_A="$(json_str id "${LAST_BODY}")"; CONTENT_A="$(json_str contentId "${LAST_BODY}")"; DIGEST_A="$(json_str digest "${LAST_BODY}")"
hit 201 "POST /api/resources（B）" -F "file=@$(win_path "${SAMPLE_B}");type=text/plain;filename=U3-B.txt" "${BASE}/api/resources"
RES_B="$(json_str id "${LAST_BODY}")"; CONTENT_B="$(json_str contentId "${LAST_BODY}")"; DIGEST_B="$(json_str digest "${LAST_BODY}")"
BLOB_A="$(blob_path "${DIGEST_A}")"; BLOB_B="$(blob_path "${DIGEST_B}")"
say "  A=${RES_A}  B=${RES_B}"
check "$(q "SELECT count(*) FROM cangshu_m1.resource")" "2" "资源行数（软删前）"

say ""
say "-- ② 回收站列表（§3.6）：只给已软删未到期的行，另带两个时间戳 --"
hit 204 "DELETE /api/resources/{A}（软删）" -X DELETE "${BASE}/api/resources/${RES_A}"
hit 200 "GET /api/resources/trash" "${BASE}/api/resources/trash"
check "$(json_num total "${LAST_BODY}")" "1" "回收站 total"
check "$(json_str status "${LAST_BODY}")" "DELETED" "条目状态"
check "$(grep -c '"deletedAt"' "${LAST_BODY}" || true)" "1" "条目带 deletedAt（契约 §1）"
check "$(grep -c '"expireAt"' "${LAST_BODY}" || true)" "1" "条目带 expireAt（契约 §1）"
check "$(grep -c '"contentId"' "${LAST_BODY}" || true)" "0" "列表项不输出 contentId"
hit 200 "GET /api/resources（普通列表不含回收站资源）" "${BASE}/api/resources"
check "$(json_num total "${LAST_BODY}")" "1" "普通列表 total"

say ""
say "-- ③ 回收站分页上限与 §3.2 同口径（2026-09-22 裁决定稿）--"
hit 400 "GET /api/resources/trash?size=201" "${BASE}/api/resources/trash?size=201"
check "$(json_str code "${LAST_BODY}")" "INVALID_ARGUMENT" "错误码"
hit 400 "GET /api/resources/trash?size=0" "${BASE}/api/resources/trash?size=0"
hit 400 "GET /api/resources/trash?page=0" "${BASE}/api/resources/trash?page=0"
hit 200 "GET /api/resources/trash?size=200" "${BASE}/api/resources/trash?size=200"

say ""
say "-- ④ 还原（§3.7）：200 回活跃列表；库里两个时间戳真正置空 --"
hit 200 "POST /api/resources/{A}/restore" -X POST "${BASE}/api/resources/${RES_A}/restore"
check "$(json_str status "${LAST_BODY}")" "READY" "还原后状态"
check "$(grep -c '"deletedAt"' "${LAST_BODY}" || true)" "0" "还原后不再带 deletedAt"
check "$(q "SELECT (deleted_at IS NULL AND expire_at IS NULL)::text FROM cangshu_m1.resource WHERE id = '${RES_A}'")" "true" "库里两时间戳为 NULL"
check "$(q "SELECT count(*) FROM cangshu_m1.resource WHERE status = 'DELETED'")" "0" "回收站已空"
hit 200 "GET /api/resources/{A}（回到详情可见）" "${BASE}/api/resources/${RES_A}"
hit 404 "POST /api/resources/{未知 UUID}/restore" -X POST "${BASE}/api/resources/00000000-0000-7000-8000-000000000000/restore"

say ""
say "-- ⑤ 清空负例（§3.8／08 §5）：缺 confirm 或为假 → 400 且一行不删 --"
hit 204 "DELETE /api/resources/{A}（再软删）" -X DELETE "${BASE}/api/resources/${RES_A}"
hit 400 "DELETE /api/resources/trash（无 confirm）" -X DELETE "${BASE}/api/resources/trash"
check "$(json_str code "${LAST_BODY}")" "INVALID_ARGUMENT" "错误码"
hit 400 "DELETE /api/resources/trash?confirm=false" -X DELETE "${BASE}/api/resources/trash?confirm=false"
check "$(q "SELECT count(*) FROM cangshu_m1.resource WHERE status = 'DELETED'")" "1" "未确认时一行都没删"
check "$(q "SELECT status FROM cangshu_m1.content WHERE id = '${CONTENT_A}'")" "READY" "未确认时内容态也没动"

say ""
say "-- ⑥ 清空正例：200 {deletedCount}；删行、引用归零的内容进待回收，字节仍在 --"
hit 200 "DELETE /api/resources/trash?confirm=true" -X DELETE "${BASE}/api/resources/trash?confirm=true"
check "$(json_num deletedCount "${LAST_BODY}")" "1" "deletedCount"
check "$(q "SELECT count(*) FROM cangshu_m1.resource WHERE status = 'DELETED'")" "0" "回收站行已删"
check "$(q "SELECT status FROM cangshu_m1.content WHERE id = '${CONTENT_A}'")" "RECLAIM_PENDING" "引用归零 → 待回收"
check "$(q "SELECT count(*) FROM cangshu_m1.location WHERE content_id = '${CONTENT_A}'")" "1" "位置行仍在（交给 GC）"
check "$([ -f "${BLOB_A}" ] && echo yes || echo no)" "yes" "字节仍在（只删引用）"

say ""
say "-- ⑦ GC 一次性作业（CLI --mode=gc）：到期硬删 ＋ 回收队列三段提交 --"
"${PSQL}" -h 127.0.0.1 -U "${CANGSHU_DB_USER}" -d "${DB}" -q \
  -c "UPDATE cangshu_m1.resource SET status='DELETED', deleted_at=now(), expire_at=now() - interval '1 second' WHERE id='${RES_B}'" >> "${SUMMARY}" 2>&1
run_job gc "${LOG_DIR}/cli-gc.out"; GC_EXIT="${JOB_EXIT}"; GC_SUMMARY="$(job_summary "${LOG_DIR}/cli-gc.out")"
say "  ${GC_SUMMARY}"
check "$(echo "${GC_SUMMARY}" | grep -c 'expiredHardDeleted=1' || true)" "1" "到期行被硬删"
check "$(echo "${GC_SUMMARY}" | grep -c 'reclaimed=2' || true)" "1" "两个内容都被回收（A 待回收、B 到期后归零）"
check "${GC_EXIT}" "0" "GC 退出码（无需人工介入）"
check "$(q "SELECT status FROM cangshu_m1.content WHERE id = '${CONTENT_A}'")" "RECLAIMED" "A 内容已回收"
check "$(q "SELECT count(*) FROM cangshu_m1.location")" "0" "位置行已删（段一）"
check "$([ -f "${BLOB_A}" ] && echo yes || echo no)" "no" "A 字节已删（段二）"
check "$([ -f "${BLOB_B}" ] && echo yes || echo no)" "no" "B 字节已删（段二）"

say ""
say "-- ⑧ 对账一次性作业（CLI --mode=reconcile）：干净态 --"
run_job reconcile "${LOG_DIR}/cli-reconcile-clean.out"
RECON_EXIT="${JOB_EXIT}"; RECON_SUMMARY="$(job_summary "${LOG_DIR}/cli-reconcile-clean.out")"
say "  ${RECON_SUMMARY}"
check "${RECON_EXIT}" "0" "干净态退出码为 0"
check "$(echo "${RECON_SUMMARY}" | grep -c 'bytesMissing=0' || true)" "1" "无缺失字节"

say ""
say "-- ⑨ 对账负例：孤儿字节隔离 ＋ 缺失字节告警（退出码 4，07 §6 非零结果）--"
ORPHAN_TEXT="仓鼠 U3 孤儿字节样本"
ORPHAN_DIGEST="$(printf '%s' "${ORPHAN_TEXT}" | sha256sum | cut -d' ' -f1)"
ORPHAN_KEY="sha256/${ORPHAN_DIGEST:0:2}/${ORPHAN_DIGEST:2:2}/${ORPHAN_DIGEST}"
mkdir -p "$(dirname "${DATA_ROOT}/${ORPHAN_KEY}")"
printf '%s' "${ORPHAN_TEXT}" > "${DATA_ROOT}/${ORPHAN_KEY}"
printf '仓鼠 U3 缺失字节样本 %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" > "${LOG_DIR}/u3-missing.txt"
hit 201 "POST /api/resources（用于制造缺失字节）" -F "file=@$(win_path "${LOG_DIR}/u3-missing.txt");type=text/plain;filename=U3-缺失.txt" "${BASE}/api/resources"
DIGEST_M="$(json_str digest "${LAST_BODY}")"
rm -f "$(blob_path "${DIGEST_M}")"
run_job reconcile "${LOG_DIR}/cli-reconcile-bad.out"
BAD_EXIT="${JOB_EXIT}"; RECON_BAD="$(job_summary "${LOG_DIR}/cli-reconcile-bad.out")"
say "  ${RECON_BAD}"
check "$(echo "${RECON_BAD}" | grep -c 'orphanFound=1' || true)" "1" "识别出 1 个孤儿字节"
check "$(echo "${RECON_BAD}" | grep -c 'orphanQuarantined=1' || true)" "1" "孤儿已被隔离"
check "$(echo "${RECON_BAD}" | grep -c 'bytesMissing=1' || true)" "1" "识别出 1 处缺失字节"
check "$(echo "${RECON_BAD}" | grep -c 'needsAttention=true' || true)" "1" "标记为需人工介入"
check "${BAD_EXIT}" "4" "对账检出需人工介入 → 退出码 4"
check "$([ -f "${DATA_ROOT}/${ORPHAN_KEY}" ] && echo yes || echo no)" "no" "孤儿已离开原内容地址"
check "$([ -f "${DATA_ROOT}/orphan/${ORPHAN_KEY}" ] && echo yes || echo no)" "yes" "孤儿已在隔离区（只移动、不覆盖）"

say ""
say "== 汇总：通过 ${PASS} ｜ 不符 ${FAIL} =="
say "serve 日志：${RUN_LOG}"
say "结构化摘要：${SUMMARY}"
say "CLI 原始输出：${LOG_DIR}/cli-gc.out、${LOG_DIR}/cli-reconcile-clean.out、${LOG_DIR}/cli-reconcile-bad.out"
if [ "${FAIL}" -ne 0 ]; then
  say "结论：有观测项与任务 28 的契约预期不符，需排查（见上方 [FAIL]）。"
  exit 1
fi
say "结论：回收站列表／还原／清空（含 400 负例与分页上限）、GC 三段提交（到期硬删＋回收队列）、"
say "      对账三类（临时／孤儿／缺失）与「需人工介入 → 非零退出」——各项与 05 §3.6–§3.8、04 §5 ②③④、07 §6 一致。"
