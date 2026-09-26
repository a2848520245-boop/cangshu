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
# 产出：八端点 3.1–3.8（含软删、回收站列表、还原、清空）的逐请求 HTTP 状态与汇总。
# 注意：confirm=true 会清空所连库的回收站；仅在受控隔离的演示库与数据根运行。
# 退出码：0＝已执行请求的状态、上传身份／去重字段、下载摘要符合预期；1＝任一检查失败。
# 仍不覆盖完整响应契约、数据库持久化与全部验收负例。
#
# 说明：本脚本是「演示与交付」材料，**不是** 08-验收规范 §2 的验收证据本身；
#      验收证据需按 §6 另行成包（含原始日志、manifest 与摘要）。

set -uo pipefail

PORT="${1:-18080}"
BASE="http://127.0.0.1:${PORT}"
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd -P)"
JAR="${ROOT_DIR}/target/cangshu-0.1.0-SNAPSHOT.jar"
DATA_ROOT="${CANGSHU_DEMO_DATA_ROOT:-${ROOT_DIR}/var/demo-data-root}"
LOG_DIR="${CANGSHU_DEMO_LOG_DIR:-${ROOT_DIR}/var/demo-logs}"

export CANGSHU_DB_URL="${CANGSHU_DB_URL:-jdbc:postgresql://127.0.0.1:5432/cangshu_m1demo?currentSchema=cangshu_m1}"
export CANGSHU_DB_USER="${CANGSHU_DB_USER:-postgres}"
export CANGSHU_DB_PASSWORD="${CANGSHU_DB_PASSWORD:-postgres}"

mkdir -p "${LOG_DIR}" "${DATA_ROOT}" "${ROOT_DIR}/var/m2repo"
LOG_DIR="$(cd "${LOG_DIR}" && pwd -P)"
DATA_ROOT="$(cd "${DATA_ROOT}" && pwd -P)"
python - "${ROOT_DIR}" "${DATA_ROOT}" "${LOG_DIR}" <<'PY' || exit 1
import os, pathlib, sys
root = pathlib.Path(sys.argv[1]).resolve()
target_path = root / 'target'
target = target_path.resolve()
if os.path.normcase(str(target)) != os.path.normcase(str(target_path)):
    print('target 指向仓库外路径；clean 前拒绝继续', file=sys.stderr)
    sys.exit(1)
for label, raw in [('数据根', sys.argv[2]), ('日志目录', sys.argv[3])]:
    value = pathlib.Path(raw).resolve()
    try:
        inside_target = os.path.normcase(os.path.commonpath([target, value])) == os.path.normcase(str(target))
    except ValueError:  # Windows 上不同盘的两个绝对路径没有公共路径。
        inside_target = False
    if inside_target:
        print(f'{label}不能在 target 内（clean 会删除它）', file=sys.stderr)
        sys.exit(1)
PY
if [ -e "${ROOT_DIR}/target/demo-data-root" ] || [ -L "${ROOT_DIR}/target/demo-data-root" ]; then
  printf '检测到旧 target/demo-data-root；为避免 clean 删除旧演示字节，已拒绝继续。请先由受控流程处理该目录。\n' >&2
  exit 1
fi
RUN_LOG="${LOG_DIR}/demo-serve.log"
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
  kill -0 "${SERVER_PID}" 2>/dev/null || abort "本轮 serve 进程已退出，拒绝请求：${label}"
  local body_file="${LOG_DIR}/body-$(echo "${label}" | tr -c 'A-Za-z0-9' '_').out"
  local status
  status="$(curl -sS --connect-timeout 3 --max-time 15 -o "$(win_path "${body_file}")" -w '%{http_code}' "$@" || echo 000)"
  if [ "${status}" = "${expect}" ]; then
    PASS=$((PASS + 1)); say "  [OK]   ${label} → ${status}（期望 ${expect}）"
  else
    FAIL=$((FAIL + 1)); say "  [FAIL] ${label} → ${status}（期望 ${expect}）"
    say "         body: $(head -c 300 "${body_file}" 2>/dev/null)"
    exit 1
  fi
  LAST_BODY="${body_file}"
}

upload_fields() {
  python - "$1" <<'PY'
import json, re, sys
try:
    with open(sys.argv[1], encoding='utf-8') as stream:
        data = json.load(stream)
    uuid = re.compile(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$', re.I)
    resource_id, content_id = data['id'], data['contentId']
    deduplicated = data['deduplicated']
    if not (isinstance(resource_id, str) and uuid.fullmatch(resource_id)
            and isinstance(content_id, str) and uuid.fullmatch(content_id)
            and type(deduplicated) is bool):
        raise ValueError('invalid upload identity or deduplicated field')
    print('\t'.join((resource_id.lower(), content_id.lower(), str(deduplicated).lower())))
except (OSError, ValueError, KeyError, TypeError, json.JSONDecodeError) as exc:
    print(f'上传响应 JSON 无效：{exc}', file=sys.stderr)
    sys.exit(1)
PY
}

health_up() {
  python - "$1" <<'PY'
import json, sys
try:
    with open(sys.argv[1], encoding='utf-8') as stream:
        sys.exit(0 if json.load(stream).get('status') == 'UP' else 1)
except (OSError, ValueError, AttributeError):
    sys.exit(1)
PY
}

health_config_matches() {
  python - "$1" "${DATA_ROOT}" <<'PY'
import json, os, pathlib, sys
try:
    with open(sys.argv[1], encoding='utf-8') as stream:
        value = json.load(stream)
    actual = pathlib.Path(value['config']['dataRoot']).resolve()
    expected = pathlib.Path(sys.argv[2]).resolve()
    sys.exit(0 if value.get('status') == 'UP' and
             os.path.normcase(str(actual)) == os.path.normcase(str(expected)) else 1)
except (OSError, ValueError, KeyError, TypeError, AttributeError):
    sys.exit(1)
PY
}

port_is_free() {
  python - "$PORT" <<'PY'
import socket, sys
try:
    with socket.create_connection(('127.0.0.1', int(sys.argv[1])), timeout=2):
        print('演示端口已有 TCP 服务，拒绝启动', file=sys.stderr)
        sys.exit(1)
except ConnectionRefusedError:
    sys.exit(0)
except OSError as exc:
    print(f'无法确认演示端口空闲：{exc}', file=sys.stderr)
    sys.exit(1)
PY
}

abort() { say "  [FAIL] $*"; exit 1; }

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
port_is_free || exit 1

if [ "${CANGSHU_DEMO_SKIP_BUILD:-0}" = "1" ]; then
  say "跳过构建（CANGSHU_DEMO_SKIP_BUILD=1）；使用现有产物：${JAR}"
  [ -f "${JAR}" ] || { say "产物不存在：${JAR}"; exit 1; }
else
  # 默认总是重建：忽略「产物已存在」以免演示跑在陈旧 jar 上（产物不随源码自动更新）。
  say "构建产物：${MVN_CMD:-mvn} -B -ntp -Dmaven.repo.local=<绝对路径> -DskipTests clean package"
  ( cd "${ROOT_DIR}" && "${MVN_CMD:-mvn}" -B -ntp "-Dmaven.repo.local=$(win_path "${ROOT_DIR}/var/m2repo")" -DskipTests clean package ) >> "${SUMMARY}" 2>&1 || {
    say "构建失败，见 ${SUMMARY}"; exit 1; }
  [ -f "${JAR}" ] || { say "构建未产出 ${JAR}"; exit 1; }
fi

say "启动 serve：java -jar <jar> --server.port=${PORT}"
java -jar "$(win_path "${JAR}")" --server.port="${PORT}" --cangshu.data-root="$(win_path "${DATA_ROOT}")" > "${RUN_LOG}" 2>&1 &
SERVER_PID=$!

READY=0
DEADLINE=$((SECONDS + 60))
while [ "${SECONDS}" -lt "${DEADLINE}" ]; do
  health_status="$(curl -sS --connect-timeout 2 --max-time 3 -o "$(win_path "${LOG_DIR}/body-health.out")" -w '%{http_code}' "${BASE}/actuator/health" 2>/dev/null)" || health_status=000
  if [ "${health_status}" = 200 ] && health_up "${LOG_DIR}/body-health.out"; then READY=1; break; fi
  if ! kill -0 "${SERVER_PID}" 2>/dev/null; then break; fi
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
health_up "${LAST_BODY}" || abort '健康端点未返回 status=UP'
hit 200 "GET /api/health" "${BASE}/api/health"
health_config_matches "${LAST_BODY}" || abort '/api/health 数据根与本轮配置不符'
kill -0 "${SERVER_PID}" 2>/dev/null || abort '本轮 serve 进程已退出，拒绝写入'

say ""
say "-- 八端点 3.1–3.4（已实现）--"
SAMPLE="${LOG_DIR}/demo-sample.txt"
printf '仓鼠 M1 演示样本 %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" > "${SAMPLE}"
SAMPLE_WIN="$(win_path "${SAMPLE}")"
hit 201 "POST /api/resources（首传）" -F "file=@${SAMPLE_WIN};type=text/plain;filename=演示样本.txt" "${BASE}/api/resources"
first_fields="$(upload_fields "${LAST_BODY}")" || abort '首传未返回有效 id、contentId、deduplicated'
IFS=$'\t' read -r RES_ID CONTENT_ID FIRST_DEDUP <<< "${first_fields}"
[ "${FIRST_DEDUP}" = false ] || abort '首传意外复用内容'
hit 201 "POST /api/resources（同内容再传 → deduplicated）" \
  -F "file=@${SAMPLE_WIN};type=text/plain;filename=演示样本-副本.txt" "${BASE}/api/resources"
second_fields="$(upload_fields "${LAST_BODY}")" || abort '重复上传未返回有效 id、contentId、deduplicated'
IFS=$'\t' read -r SECOND_ID SECOND_CONTENT_ID SECOND_DEDUP <<< "${second_fields}"
[ "${SECOND_ID}" != "${RES_ID}" ] && [ "${SECOND_CONTENT_ID}" = "${CONTENT_ID}" ] &&
  [ "${SECOND_DEDUP}" = true ] || abort '重复上传未得到不同资源、相同内容及 deduplicated=true'
hit 200 "GET /api/resources?page=1&size=20" "${BASE}/api/resources?page=1&size=20"
hit 200 "GET /api/resources?name=演示样本" "${BASE}/api/resources?name=%E6%BC%94%E7%A4%BA%E6%A0%B7%E6%9C%AC"
hit 200 "GET /api/resources/{id}" "${BASE}/api/resources/${RES_ID}"
hit 200 "GET /api/resources/{id}/content" "${BASE}/api/resources/${RES_ID}/content"
sample_digest="$(sha256sum "${SAMPLE}" | cut -d ' ' -f1)" || abort '样本摘要计算失败'
download_digest="$(sha256sum "${LAST_BODY}" | cut -d ' ' -f1)" || abort '下载摘要计算失败'
[[ "${sample_digest}" =~ ^[0-9a-f]{64}$ && "${download_digest}" =~ ^[0-9a-f]{64}$ ]] || abort '摘要格式无效'
[ "${sample_digest}" = "${download_digest}" ] || abort '下载字节 SHA-256 与样本不一致'
hit 200 "GET /api/resources/{id}/content?inline=1" "${BASE}/api/resources/${RES_ID}/content?inline=1"
say "  资源 id=${RES_ID:-<无>} contentId=${CONTENT_ID:-<无>}"

say ""
say "-- 负例（已实现口径）--"
hit 404 "GET /api/resources/{未知 UUID}" "${BASE}/api/resources/00000000-0000-7000-8000-000000000000"
hit 400 "GET /api/resources?size=201（I11 上限）" "${BASE}/api/resources?size=201"
hit 400 "GET /api/resources?size=0" "${BASE}/api/resources?size=0"
hit 400 "GET /api/resources/not-a-uuid" "${BASE}/api/resources/not-a-uuid"
hit 400 "GET /api/resources/{id}/content?inline=true" "${BASE}/api/resources/${RES_ID}/content?inline=true"
hit 400 "POST /api/resources（application/json，媒体类型不受支持）" \
  -X POST -H 'Content-Type: application/json' -d '{}' "${BASE}/api/resources"

say ""
say "-- 八端点 3.5（任务 6 已实现：软删 204，资源进回收站）--"
hit 204 "DELETE /api/resources/{id} → 204 软删（写 deletedAt／expireAt）" -X DELETE "${BASE}/api/resources/${RES_ID}"
hit 404 "GET /api/resources/{id}（软删后对普通详情不可见）" "${BASE}/api/resources/${RES_ID}"
hit 204 "DELETE /api/resources/{id}（重复软删 → 幂等 204，不刷新到期时刻）" -X DELETE "${BASE}/api/resources/${RES_ID}"
hit 404 "DELETE /api/resources/{未知 UUID}（已硬删／不存在 → 404）" \
  -X DELETE "${BASE}/api/resources/00000000-0000-7000-8000-000000000000"

say ""
say "-- 八端点 3.6–3.8（任务 28 已实现：回收站列表／还原／清空）--"
hit 200 "GET /api/resources/trash（回收站列表）" "${BASE}/api/resources/trash"
hit 200 "GET /api/resources/trash?size=200（分页上限内）" "${BASE}/api/resources/trash?size=200"
hit 400 "GET /api/resources/trash?size=201（§3.6 上限）" "${BASE}/api/resources/trash?size=201"
hit 400 "DELETE /api/resources/trash（缺显式确认 → 不删任何内容）" -X DELETE "${BASE}/api/resources/trash"
hit 200 "POST /api/resources/{id}/restore（把 3.5 软删的资源还原）" -X POST "${BASE}/api/resources/${RES_ID}/restore"
hit 200 "GET /api/resources/{id}（还原后回到详情可见）" "${BASE}/api/resources/${RES_ID}"
[ "${FAIL}" -eq 0 ] || abort '前置请求失败，拒绝清空回收站'
kill -0 "${SERVER_PID}" 2>/dev/null || abort '本轮 serve 进程已退出，拒绝清空回收站'
hit 200 "DELETE /api/resources/trash?confirm=true（清空回收站）" -X DELETE "${BASE}/api/resources/trash?confirm=true"

say ""
say "== 汇总：通过 ${PASS} ｜ 不符 ${FAIL} =="
say "serve 日志：${RUN_LOG}"
if [ "${FAIL}" -ne 0 ]; then
  say "结论：有端点实际状态与预期不符，需排查（见上方 [FAIL]）。"
  exit 1
fi
say "结论：八端点 3.1–3.8 的真实 HTTP 行为与 05-接口契约及负例口径一致（含 3.5–3.8 的回收站闭环）。"
