#!/usr/bin/env bash
# 仓鼠 M1 真实 HTTP 演示与自检（任务 18 · S18-c）
#
# 用法：
#   bash scripts/demo-m1.sh [端口]
#
# 前置：
#   - JAVA_HOME 指向 JDK 21（Windows 路径形式，供 Maven 启动脚本使用）；java 在 PATH 上。
#   - Maven（脚本默认用 PATH 上的 mvn；本机 Maven 未入 PATH 时用 MVN_CMD 覆盖，例如
#     MVN_CMD='E:/IDEA/IntelliJ IDEA 2025.2.1/plugins/maven/lib/maven3/bin/mvn.cmd'）。
#   - 本机 PostgreSQL 17 在跑。
#   - 数据库按《07-M1-运行手册》§3「禁空库降级」人工初始化：先建库，再人工执行
#     db/migration/V1__init.sql 与 V2__search_indexes.sql（各带 -v script_sha256=<脚本SHA-256>）。
#     默认库名 cangshu_m1demo，可用 CANGSHU_DB_URL / CANGSHU_DB_USER / CANGSHU_DB_PASSWORD 覆盖。
#
# 产出：逐端点请求与响应状态；**未实现端点会显式标注**（属任务 28），不得当作已具备。
# 退出码：0＝全部符合预期；1＝serve 未就绪或有端点实际状态与预期不符（自检失败）。
#
# 说明：本脚本是「演示与交付」材料，**不是** 08-验收规范 §2 的验收证据本身；
#      验收证据需按 §6 另行成包（含原始日志、manifest 与摘要）。

set -uo pipefail

PORT="${1:-18080}"
BASE="http://127.0.0.1:${PORT}"
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
JAR="${ROOT_DIR}/target/cangshu-0.1.0-SNAPSHOT.jar"
DATA_ROOT="${CANGSHU_DEMO_DATA_ROOT:-${ROOT_DIR}/target/demo-data-root}"
LOG_DIR="${CANGSHU_DEMO_LOG_DIR:-${ROOT_DIR}/target/demo-logs}"
RUN_LOG="${LOG_DIR}/demo-serve.log"

export CANGSHU_DB_URL="${CANGSHU_DB_URL:-jdbc:postgresql://127.0.0.1:5432/cangshu_m1demo?currentSchema=cangshu_m1}"
export CANGSHU_DB_USER="${CANGSHU_DB_USER:-postgres}"
export CANGSHU_DB_PASSWORD="${CANGSHU_DB_PASSWORD:-postgres}"

mkdir -p "${LOG_DIR}" "${DATA_ROOT}"
PASS=0
FAIL=0
LAST_BODY=""
SUMMARY="${LOG_DIR}/demo-summary.txt"
: > "${SUMMARY}"

say() { printf '%s\n' "$*" | tee -a "${SUMMARY}"; }

# Windows 宿主上的 java / curl / git 不认 POSIX 路径：交给它们之前统一转换为 Windows 形式。
win_path() {
  if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s' "$1"; fi
}

# hit <期望状态> <说明> <curl 参数...>
hit() {
  local expect="$1"; shift
  local label="$1"; shift
  local body_file="${LOG_DIR}/body-$(echo "${label}" | tr -c 'A-Za-z0-9' '_').out"
  local status
  status="$(curl -sS -o "$(win_path "${body_file}")" -w '%{http_code}' "$@" || echo 000)"
  if [ "${status}" = "${expect}" ]; then
    PASS=$((PASS + 1)); say "  [OK]   ${label} → ${status}（期望 ${expect}）"
  else
    FAIL=$((FAIL + 1)); say "  [FAIL] ${label} → ${status}（期望 ${expect}）"
    say "         body: $(head -c 300 "${body_file}" 2>/dev/null)"
  fi
  LAST_BODY="${body_file}"
}

json_field() { sed -n "s/.*\"$1\":\"\([^\"]*\)\".*/\1/p" "$2" | head -1; }

cleanup() {
  if [ -n "${SERVER_PID:-}" ] && kill -0 "${SERVER_PID}" 2>/dev/null; then
    kill "${SERVER_PID}" 2>/dev/null
    wait "${SERVER_PID}" 2>/dev/null
    say "  已在演示结束后停止 serve 进程（pid ${SERVER_PID}）"
  fi
}
trap cleanup EXIT

say "== 仓鼠 M1 真实 HTTP 演示（任务 18 · S18-c）=="
say "时间：$(date '+%Y-%m-%dT%H:%M:%S%z')"
say "仓（提交）：$(cd "${ROOT_DIR}" && git rev-parse HEAD 2>/dev/null || echo '不可观测')"
say "工作树改动数：$(cd "${ROOT_DIR}" && git status --porcelain=v1 --untracked-files=all 2>/dev/null | wc -l | tr -d ' ')"
say "JDBC：${CANGSHU_DB_URL}"
say "数据根：$(win_path "${DATA_ROOT}")"
say ""

if [ "${CANGSHU_DEMO_SKIP_BUILD:-0}" = "1" ]; then
  say "跳过构建（CANGSHU_DEMO_SKIP_BUILD=1）；使用现有产物：${JAR}"
  [ -f "${JAR}" ] || { say "产物不存在：${JAR}"; exit 1; }
else
  # 默认总是重建：忽略「产物已存在」以免演示跑在陈旧 jar 上（产物不随源码自动更新）。
  say "构建产物：${MVN_CMD:-mvn} -B -ntp -Dmaven.repo.local=var/m2repo -DskipTests package"
  ( cd "${ROOT_DIR}" && "${MVN_CMD:-mvn}" -B -ntp -Dmaven.repo.local=var/m2repo -DskipTests package ) >> "${SUMMARY}" 2>&1 || {
    say "构建失败，见 ${SUMMARY}"; exit 1; }
  [ -f "${JAR}" ] || { say "构建未产出 ${JAR}"; exit 1; }
fi

say "启动 serve：java -jar <jar> --server.port=${PORT}"
java -jar "$(win_path "${JAR}")" --server.port="${PORT}" --cangshu.data-root="$(win_path "${DATA_ROOT}")" > "${RUN_LOG}" 2>&1 &
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
say ""

say "-- 非端点（07 §2，I9）--"
hit 200 "GET /actuator/health" "${BASE}/actuator/health"
hit 200 "GET /api/health" "${BASE}/api/health"

say ""
say "-- 八端点 3.1–3.4（已实现）--"
SAMPLE="${LOG_DIR}/demo-sample.txt"
printf '仓鼠 M1 演示样本 %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" > "${SAMPLE}"
SAMPLE_WIN="$(win_path "${SAMPLE}")"
hit 201 "POST /api/resources（首传）" -F "file=@${SAMPLE_WIN};type=text/plain;filename=演示样本.txt" "${BASE}/api/resources"
RES_ID="$(json_field id "${LAST_BODY}")"
CONTENT_ID="$(json_field contentId "${LAST_BODY}")"
hit 201 "POST /api/resources（同内容再传 → deduplicated）" \
  -F "file=@${SAMPLE_WIN};type=text/plain;filename=演示样本-副本.txt" "${BASE}/api/resources"
hit 200 "GET /api/resources?page=1&size=20" "${BASE}/api/resources?page=1&size=20"
hit 200 "GET /api/resources?name=演示样本" "${BASE}/api/resources?name=%E6%BC%94%E7%A4%BA%E6%A0%B7%E6%9C%AC"
if [ -n "${RES_ID}" ]; then
  hit 200 "GET /api/resources/{id}" "${BASE}/api/resources/${RES_ID}"
  hit 200 "GET /api/resources/{id}/content" "${BASE}/api/resources/${RES_ID}/content"
  hit 200 "GET /api/resources/{id}/content?inline=1" -o /dev/null "${BASE}/api/resources/${RES_ID}/content?inline=1"
else
  say "  [SKIP] 详情／下载：上传未取得资源 ID"
fi
say "  资源 id=${RES_ID:-<无>} contentId=${CONTENT_ID:-<无>}"

say ""
say "-- 负例（已实现口径）--"
hit 404 "GET /api/resources/{未知 UUID}" "${BASE}/api/resources/00000000-0000-7000-8000-000000000000"
hit 400 "GET /api/resources?size=201（I11 上限）" "${BASE}/api/resources?size=201"
hit 400 "GET /api/resources?size=0" "${BASE}/api/resources?size=0"
hit 400 "GET /api/resources/not-a-uuid" "${BASE}/api/resources/not-a-uuid"
if [ -n "${RES_ID}" ]; then
  hit 400 "GET /api/resources/{id}/content?inline=true" "${BASE}/api/resources/${RES_ID}/content?inline=true"
fi
hit 400 "POST /api/resources（application/json，媒体类型不受支持）" \
  -X POST -H 'Content-Type: application/json' -d '{}' "${BASE}/api/resources"

say ""
say "-- 八端点 3.5（任务 6 已实现：软删 204，资源进回收站）--"
if [ -n "${RES_ID}" ]; then
  hit 204 "DELETE /api/resources/{id} → 204 软删（写 deletedAt／expireAt）" -X DELETE "${BASE}/api/resources/${RES_ID}"
  hit 404 "GET /api/resources/{id}（软删后对普通详情不可见）" "${BASE}/api/resources/${RES_ID}"
  hit 204 "DELETE /api/resources/{id}（重复软删 → 幂等 204，不刷新到期时刻）" -X DELETE "${BASE}/api/resources/${RES_ID}"
else
  say "  [SKIP] 软删：上传未取得资源 ID"
fi
hit 404 "DELETE /api/resources/{未知 UUID}（已硬删／不存在 → 404）" \
  -X DELETE "${BASE}/api/resources/00000000-0000-7000-8000-000000000000"

say ""
say "-- 未实现端点（任务 28；此处只演示当前真实响应，不得当作已具备）--"
hit 400 "GET /api/resources/trash（任务 28 未实现 → 路径落在 {id} 上，非 UUID）" "${BASE}/api/resources/trash"

say ""
say "== 汇总：通过 ${PASS} ｜ 不符 ${FAIL} =="
say "serve 日志：${RUN_LOG}"
if [ "${FAIL}" -ne 0 ]; then
  say "结论：有端点实际状态与预期不符，需排查（见上方 [FAIL]）。"
  exit 1
fi
say "结论：已实现端点的行为与 05-接口契约 §3.1–§3.5 及负例口径一致；3.6–3.8 未实现（如实标注）。"
