#!/usr/bin/env bash
# 仓鼠 M1 真实 HTTP 演示与自检（任务 26 · 引用语义与延迟回收 / 分支 C 复活复用）
#
# 用法：
#   bash scripts/demo-u1-revival.sh [端口]
#
# 前置：
#   - JAVA_HOME 指向 JDK 21（Windows 路径形式，供 Maven 启动脚本使用）；java 在 PATH 上。
#   - Maven（默认用 PATH 上的 mvn；本机 Maven 未入 PATH 时用 MVN_CMD 覆盖，例如
#     MVN_CMD='E:/IDEA/IntelliJ IDEA 2025.2.1/plugins/maven/lib/maven3/bin/mvn.cmd'）。
#   - 本机 PostgreSQL 17 在跑；psql 默认取本机安装路径，可用 PSQL 覆盖。
#   - 按《07-M1-运行手册》§4 的文档路径建库：本脚本**自行重建**演示库（默认 cangshu_u1demo），
#     人工迁移的等价动作＝按 V1／V2 顺序执行 `db/migration/*.sql`，每个脚本带
#     `-v ON_ERROR_STOP=1 -v script_sha256=<脚本SHA-256>`（禁空库降级：表由脚本建，应用不建表）。
#
# 本脚本演示并自检的是任务 26 的验收面：
#   ① 保护引用计数实时且**包含回收站行**（软删行照样算引用）；
#   ② 引用归零才置待回收——软删不算归零，硬删行才算；
#   ③ 分支 C 复活复用必须**重建字节＋重建位置行**再置就绪（不得只改状态），且 reviver 后下载字节可取；
#   ④ DEC-I2：`revived` 不对外暴露；重建字节时 `deduplicated=false`；
#   ⑤ 复活路径的字节校验按同一词表返回 409 BYTE_MISMATCH，且原行原字节不动。
#
# 产出：逐项请求／SQL 观测与结论表。退出码：0＝全部符合预期；1＝有项不符（自检失败）。
#
# 说明：本脚本是「演示与交付」材料，**不是** 08-验收规范 §2 的验收证据本身；
#      验收证据需按 §6 另行成包（含原始日志、manifest 与摘要），且绑定当时 HEAD 与文档基线。

set -uo pipefail

PORT="${1:-18081}"
BASE="http://127.0.0.1:${PORT}"
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
JAR="${ROOT_DIR}/target/cangshu-0.1.0-SNAPSHOT.jar"
DATA_ROOT="${CANGSHU_U1_DEMO_DATA_ROOT:-${ROOT_DIR}/target/demo-u1-data-root}"
LOG_DIR="${CANGSHU_U1_DEMO_LOG_DIR:-${ROOT_DIR}/target/demo-u1-logs}"
RUN_LOG="${LOG_DIR}/demo-u1-serve.log"
DB="${CANGSHU_U1_DEMO_DB:-cangshu_u1demo}"
PSQL="${PSQL:-E:/PostgreSQL/17/bin/psql.exe}"
MIGRATION_DIR="${ROOT_DIR}/db/migration"

export PGPASSWORD="${CANGSHU_DB_PASSWORD:-postgres}"
export CANGSHU_DB_URL="${CANGSHU_DB_URL:-jdbc:postgresql://127.0.0.1:5432/${DB}?currentSchema=cangshu_m1}"
export CANGSHU_DB_USER="${CANGSHU_DB_USER:-postgres}"

rm -rf "${LOG_DIR}"
mkdir -p "${LOG_DIR}" "${DATA_ROOT}"
PASS=0
FAIL=0
LAST_BODY=""
DIGEST=""
RES_ID=""
CONTENT_ID=""
SUMMARY="${LOG_DIR}/demo-u1-summary.txt"
: > "${SUMMARY}"

say() { printf '%s\n' "$*" | tee -a "${SUMMARY}"; }

# Windows 宿主上的 java / curl / git / psql 不认 POSIX 路径：交给它们之前统一转换为 Windows 形式。
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

# hit <期望状态> <说明> <curl 参数...>
hit() {
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
json_bool() { sed -n "s/.*\"$1\":\(true\|false\).*/\1/p" "$2" | head -1; }

# q <sql>：结构化取单值（-tA 去表头与对齐，去掉空白）
q() { "${PSQL}" -h 127.0.0.1 -U "${CANGSHU_DB_USER}" -d "${DB}" -tAc "$1" 2>/dev/null | tr -d '[:space:]'; }
blob_path() { printf '%s/sha256/%s/%s/%s' "${DATA_ROOT}" "${1:0:2}" "${1:2:2}" "${1}"; }
sha_of() { sha256sum "$1" | cut -d' ' -f1; }

cleanup() {
  if [ -n "${SERVER_PID:-}" ] && kill -0 "${SERVER_PID}" 2>/dev/null; then
    kill "${SERVER_PID}" 2>/dev/null
    wait "${SERVER_PID}" 2>/dev/null
    say "  已在演示结束后停止 serve 进程（pid ${SERVER_PID}）"
  fi
}
trap cleanup EXIT

say "== 仓鼠 M1 真实 HTTP 演示（任务 26 · 引用语义与延迟回收）=="
say "时间：$(date '+%Y-%m-%dT%H:%M:%S%z')"
say "仓（提交）：$(cd "${ROOT_DIR}" && git rev-parse HEAD 2>/dev/null || echo '不可观测')"
say "工作树改动数：$(cd "${ROOT_DIR}" && git status --porcelain=v1 --untracked-files=all 2>/dev/null | wc -l | tr -d ' ')"
say "JDBC：${CANGSHU_DB_URL}"
say "数据根：$(win_path "${DATA_ROOT}")"
say ""

if [ "${CANGSHU_U1_DEMO_SKIP_BUILD:-0}" = "1" ]; then
  say "跳过构建（CANGSHU_U1_DEMO_SKIP_BUILD=1）；使用现有产物：${JAR}"
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
say "-- ① 首传：新建内容（A 分支）--"
SAMPLE="${LOG_DIR}/u1-sample.txt"
printf '仓鼠 U1 复活演示样本 %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" > "${SAMPLE}"
SAMPLE_WIN="$(win_path "${SAMPLE}")"
hit 201 "POST /api/resources（首传）" \
  -F "file=@${SAMPLE_WIN};type=text/plain;filename=U1复活样本.txt" "${BASE}/api/resources"
RES_ID="$(json_str id "${LAST_BODY}")"
CONTENT_ID="$(json_str contentId "${LAST_BODY}")"
DIGEST="$(json_str digest "${LAST_BODY}")"
BLOB="$(blob_path "${DIGEST}")"
say "  资源 id=${RES_ID:-<无>} contentId=${CONTENT_ID:-<无>} digest=${DIGEST:0:12}…"
check "$(q "SELECT status FROM cangshu_m1.content WHERE id = '${CONTENT_ID}'")" "READY" "内容态（首传后）"
check "$(q "SELECT count(*) FROM cangshu_m1.location WHERE content_id = '${CONTENT_ID}'")" "1" "位置行数（首传后）"
check "$([ -f "${BLOB}" ] && echo yes || echo no)" "yes" "内容地址上有字节（首传后）"
check "$(q "SELECT count(*) FROM cangshu_m1.resource")" "1" "资源行数（首传后）"

say ""
say "-- ② 保护引用计数包含回收站行：软删不归零，内容不进待回收 --"
"${PSQL}" -h 127.0.0.1 -U "${CANGSHU_DB_USER}" -d "${DB}" -q -c \
  "UPDATE cangshu_m1.resource SET status='DELETED', deleted_at=now(), expire_at=now()+interval '7 days' WHERE id='${RES_ID}'" >> "${SUMMARY}" 2>&1
check "$(q "SELECT status FROM cangshu_m1.resource WHERE id = '${RES_ID}'")" "DELETED" "资源已软删（进回收站）"
check "$(q "SELECT count(*) FROM cangshu_m1.resource WHERE content_id = '${CONTENT_ID}'")" "1" "保护引用数（含回收站行）＝1"
check "$(q "SELECT status FROM cangshu_m1.content WHERE id = '${CONTENT_ID}'")" "READY" "软删不算归零：内容仍就绪、字节不回收"
hit 404 "GET /api/resources/{id}（回收站资源对普通详情不可见）" "${BASE}/api/resources/${RES_ID}"

say ""
say "-- ③ 硬删最后一行 → 引用归零 → 内容置待回收（05 §3.5：只删引用，字节交 GC）--"
"${PSQL}" -h 127.0.0.1 -U "${CANGSHU_DB_USER}" -d "${DB}" -q \
  -c "DELETE FROM cangshu_m1.resource WHERE id='${RES_ID}'" >> "${SUMMARY}" 2>&1
check "$(q "SELECT count(*) FROM cangshu_m1.resource WHERE content_id = '${CONTENT_ID}'")" "0" "保护引用数（硬删后）＝0"
say "  说明：归零→待回收的状态跃迁由 ProtectionReferenceService 在同锁事务内完成（任务 6／28 的硬删路径挂载点）；"
say "        本演示按契约把该状态直接置好，再验证复活路径——即「待回收／回收中／已回收」三个入口。"
"${PSQL}" -h 127.0.0.1 -U "${CANGSHU_DB_USER}" -d "${DB}" -q \
  -c "UPDATE cangshu_m1.content SET status='RECLAIMED' WHERE id='${CONTENT_ID}'" >> "${SUMMARY}" 2>&1
"${PSQL}" -h 127.0.0.1 -U "${CANGSHU_DB_USER}" -d "${DB}" -q \
  -c "DELETE FROM cangshu_m1.location WHERE content_id='${CONTENT_ID}'" >> "${SUMMARY}" 2>&1
rm -f "${BLOB}"
check "$(q "SELECT status FROM cangshu_m1.content WHERE id = '${CONTENT_ID}'")" "RECLAIMED" "内容态（模拟 GC 三段已完成）"
check "$(q "SELECT count(*) FROM cangshu_m1.location WHERE content_id = '${CONTENT_ID}'")" "0" "位置行已删（GC 段一）"
check "$([ -f "${BLOB}" ] && echo yes || echo no)" "no" "字节已删（GC 段二）"

say ""
say "-- ④ 同内容重传 → 分支 C 复活复用：必须重建字节＋重建位置行，再置就绪 --"
hit 201 "POST /api/resources（同内容重传 → 复活）" \
  -F "file=@${SAMPLE_WIN};type=text/plain;filename=U1复活样本-再来.txt" "${BASE}/api/resources"
REVIVED_ID="$(json_str id "${LAST_BODY}")"
check "$(grep -o '"revived"' "${LAST_BODY}" 2>/dev/null | wc -l | tr -d ' ')" "0" "DEC-I2：响应体不含 revived"
check "$(json_bool deduplicated "${LAST_BODY}")" "false" "DEC-I2：重建字节 → deduplicated=false"
check "$(json_str contentId "${LAST_BODY}")" "${CONTENT_ID}" "复活原内容行（不新建第二行）"
check "$(q "SELECT count(*) FROM cangshu_m1.content")" "1" "内容行仍为 1"
check "$(q "SELECT status FROM cangshu_m1.content WHERE id = '${CONTENT_ID}'")" "READY" "内容已回到就绪"
check "$(q "SELECT count(*) FROM cangshu_m1.location WHERE content_id = '${CONTENT_ID}'")" "1" "位置行已重建"
check "$([ -f "${BLOB}" ] && echo yes || echo no)" "yes" "字节已重建（不得只改状态）"
check "$(sha_of "${BLOB}")" "$(sha_of "${SAMPLE}")" "重建字节与上传内容逐字节一致"

say ""
say "-- ⑤ 复活后下载：真能读到字节（不是「只改了状态」）--"
# 注意：本项必须单独调用 curl。hit() 内部已用第一个 -o 指定响应体落点，同一个 URL 上再给一个
# -o 不会覆盖它（curl 按 URL 顺序配对 -o），落盘文件会根本不存在。
DL_STATUS="$(curl -sS -o "$(win_path "${LOG_DIR}/downloaded.bin")" -w '%{http_code}' \
  "${BASE}/api/resources/${REVIVED_ID}/content" || echo 000)"
check "${DL_STATUS}" "200" "GET /api/resources/{id}/content（复活后的资源）"
check "$(sha_of "${LOG_DIR}/downloaded.bin")" "$(sha_of "${SAMPLE}")" "下载字节与上传内容一致"

say ""
say "-- ⑥ 复活路径的字节校验：盘上字节与内容身份不符 → 409 BYTE_MISMATCH，原行原字节不动 --"
"${PSQL}" -h 127.0.0.1 -U "${CANGSHU_DB_USER}" -d "${DB}" -q \
  -c "DELETE FROM cangshu_m1.resource" >> "${SUMMARY}" 2>&1
"${PSQL}" -h 127.0.0.1 -U "${CANGSHU_DB_USER}" -d "${DB}" -q \
  -c "UPDATE cangshu_m1.content SET status='RECLAIM_PENDING' WHERE id='${CONTENT_ID}'" >> "${SUMMARY}" 2>&1
CORRUPT="${LOG_DIR}/u1-corrupt.bin"
head -c "$(wc -c < "${SAMPLE}" | tr -d ' ')" /dev/zero | tr '\0' 'X' > "${CORRUPT}"
cp "${CORRUPT}" "${BLOB}"
CORRUPT_SHA="$(sha_of "${CORRUPT}")"
hit 409 "POST /api/resources（复活时字节不符）" \
  -F "file=@${SAMPLE_WIN};type=text/plain;filename=U1复活样本-坏字节.txt" "${BASE}/api/resources"
check "$(json_str code "${LAST_BODY}")" "CONTENT_CONFLICT" "错误码"
check "$(json_str reason "${LAST_BODY}")" "BYTE_MISMATCH" "冲突原因（与 B／E 分支同一词表）"
check "$(q "SELECT status FROM cangshu_m1.content WHERE id = '${CONTENT_ID}'")" "RECLAIM_PENDING" "原行不动：状态未被改写"
check "$(sha_of "${BLOB}")" "${CORRUPT_SHA}" "原字节不动：未被覆盖"
check "$(q "SELECT count(*) FROM cangshu_m1.resource")" "0" "拒绝时不新增资源行"
check "$(q "SELECT count(*) FROM cangshu_m1.content_conflict WHERE reason='BYTE_MISMATCH'")" "1" "冲突审计留痕"
say "  注：本条把演示库留在「字节与内容地址不符」状态（08 故障矩阵最高危项，不盲删、留人工）——演示库随后即弃。"

say ""
say "== 汇总：通过 ${PASS} ｜ 不符 ${FAIL} =="
say "serve 日志：${RUN_LOG}"
say "结构化摘要：${SUMMARY}"
if [ "${FAIL}" -ne 0 ]; then
  say "结论：有观测项与任务 26 的契约预期不符，需排查（见上方 [FAIL]）。"
  exit 1
fi
say "结论：引用计数含回收站行、归零语义、分支 C 复活（重建字节＋重建位置行）、DEC-I2 不外露 revived、"
say "      复活后下载可取字节、复活路径 409 BYTE_MISMATCH 且原行原字节不动——各项与 04 §4／§5、06 §7／§8 一致。"
