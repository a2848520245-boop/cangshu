#!/usr/bin/env bash
# 仓鼠 M1 交付态演示与自检：Compose 骨架与 PostgreSQL 持久化（任务 16；07-运行手册 §3、08-验收规范 §1 ACC-G6）
#
# 用法：
#   bash scripts/demo-u5-compose.sh
#
# 前置：Docker 引擎在跑（本机 docker 不在 PATH，脚本按安装目录完整路径调用）；
#      JAVA_HOME/MVN_CMD 供构建产物用（或先自行 package 并设 CANGSHU_U5_SKIP_BUILD=1）。
#
# 本脚本按 08 §1 的 **ACC-G6 四项**逐项新验（不在开发态「复用」）：
#   ① 初始化：全新环境从零起库 → **人工执行迁移** → 起应用 → 上传/列表/详情/下载闭环；
#   ② 重启：重启应用后数据仍可定位（PG named volume ＋ 字节 bind mount）；
#   ③ 新卷恢复：**同批备份**（PG 逻辑备份 ＋ 字节目录复制）→ 删卷删字节 → 恢复 → 资源仍可定位；
#   ④ 更换字节根：复制字节、**只改根配置**、相对存储键不变，资源仍可定位。
#
# 失败即退出码 1。说明：本脚本是「演示与交付」材料，**不是** 08 §2 的验收证据本身。

set -uo pipefail

APP_PORT="${CANGSHU_APP_PORT:-18090}"
DB_PORT="${CANGSHU_DB_PORT:-15432}"
DB_NAME="${CANGSHU_DB_NAME:-cangshu}"
DB_USER="${CANGSHU_DB_USER:-postgres}"
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
JAR="${ROOT_DIR}/target/cangshu-0.1.0-SNAPSHOT.jar"
BLOBS="${ROOT_DIR}/cangshu-blobs"
BLOBS_ALT="${ROOT_DIR}/cangshu-blobs-alt"
BLOBS_BAK="${ROOT_DIR}/cangshu-blobs-backup"
BACKUP_DIR="${ROOT_DIR}/target/u5-compose-backup"
LOG_DIR="${ROOT_DIR}/target/demo-u5-logs"
BASE="http://127.0.0.1:${APP_PORT}"
SUMMARY="${LOG_DIR}/demo-u5-summary.txt"

export CANGSHU_APP_PORT="${APP_PORT}"
export CANGSHU_DB_PORT="${DB_PORT}"
export CANGSHU_DB_NAME="${DB_NAME}"
export CANGSHU_DB_USER="${DB_USER}"
export CANGSHU_DB_PASSWORD="${CANGSHU_DB_PASSWORD:-postgres}"

# 本机 docker 不在 PATH。注意：**凭据助手** `docker-credential-desktop.exe` 与 docker.exe 同目录，
# 只写 docker.exe 的完整路径仍会让 helper 解析失败（error getting credentials … not found in %PATH%，
# 因为 ~/.docker/config.json 里 credsStore=desktop）。因此把 Docker 的 bin 目录整体并入 PATH 再按名调用。
DOCKER_BIN_DIR="/c/Program Files/Docker/Docker/resources/bin"
if [ -d "${DOCKER_BIN_DIR}" ] && ! command -v docker >/dev/null 2>&1; then
  export PATH="${DOCKER_BIN_DIR}:${PATH}"
fi
DOCKER="${DOCKER:-docker}"
dc() { "${DOCKER}" compose "$@"; }

mkdir -p "${LOG_DIR}" "${BACKUP_DIR}"
PASS=0
FAIL=0
LAST_BODY=""
: > "${SUMMARY}"

say() { printf '%s\n' "$*" | tee -a "${SUMMARY}"; }
check() { # <实际> <期望> <说明>
  if [ "$1" = "$2" ]; then
    PASS=$((PASS + 1)); say "  [OK]   $3 → $1（期望 $2）"
  else
    FAIL=$((FAIL + 1)); say "  [FAIL] $3 → $1（期望 $2）"
  fi
}
sha_of() { sha256sum "$1" | cut -d' ' -f1; }
q() { dc exec -T db psql -U "${DB_USER}" -d "${DB_NAME}" -tAc "$1" 2>/dev/null | tr -d '[:space:]'; }
blob_path() { printf '%s/sha256/%s/%s/%s' "$1" "${2:0:2}" "${2:2:2}" "${2}"; }
json_str() { sed -n "s/.*\"$1\":\"\([^\"]*\)\".*/\1/p" "$2" | head -1; }
json_num() { sed -n "s/.*\"$1\":\([0-9-]*\).*/\1/p" "$2" | head -1; }
# 宿主 curl 是 Windows 程序：只认 Windows 路径（且**不认 `/dev/null`**，写它会以退出码非零失败）
win_path() {
  if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s' "$1"; fi
}
# 就绪判定看**状态码**而非 curl 退出码：本机 curl 写 /dev/null 会非零退出，会让「已就绪」被误判
http_status() { curl -sS -o "$(win_path "${LOG_DIR}/.probe.out")" -w '%{http_code}' --max-time 5 "$1" 2>/dev/null || true; }

wait_health() { # <超时秒>
  for _ in $(seq 1 "$1"); do
    if [ "$(http_status "${BASE}/api/health")" = "200" ]; then return 0; fi
    sleep 1
  done
  return 1
}

wait_db_healthy() {
  for _ in $(seq 1 60); do
    if [ "$(dc ps db --format '{{.Health}}' 2>/dev/null | tr -d '[:space:]')" = "healthy" ]; then return 0; fi
    sleep 2
  done
  return 1
}

app_log() { dc logs --no-log-prefix app 2>&1 | tail -"${1:-8}"; }

say "== 仓鼠 M1 交付态演示（任务 16 · Compose 与 PostgreSQL 持久化）=="
say "时间：$(date '+%Y-%m-%dT%H:%M:%S%z')"
say "仓（提交）：$(cd "${ROOT_DIR}" && git rev-parse HEAD 2>/dev/null || echo '不可观测')"
say "工作树改动数：$(cd "${ROOT_DIR}" && git status --porcelain=v1 --untracked-files=all 2>/dev/null | wc -l | tr -d ' ')"
say "docker：$("${DOCKER}" version --format '{{.Server.Version}}' 2>/dev/null || echo '引擎不可用') ｜ 应用端口 ${APP_PORT} ｜ 库端口 ${DB_PORT}"
say ""

if [ "${CANGSHU_U5_SKIP_BUILD:-0}" = "1" ]; then
  say "跳过构建（CANGSHU_U5_SKIP_BUILD=1）"
else
  say "-- 构建产物（与开发态同一份 jar）--"
  ( cd "${ROOT_DIR}" && "${MVN_CMD:-mvn}" -B -ntp -Dmaven.repo.local=var/m2repo -DskipTests package ) \
    >> "${SUMMARY}" 2>&1 || { say "构建失败，见 ${SUMMARY}"; exit 1; }
  [ -f "${JAR}" ] || { say "构建未产出 ${JAR}"; exit 1; }
  say "  产物：$(basename "${JAR}")（$(wc -c < "${JAR}" | tr -d ' ') 字节）"
fi

# ────────────────────────── ① 初始化（全新环境）──────────────────────────
say ""
say "-- ① 初始化：全新环境 → 起库 → 人工迁移 → 起应用 → 端到端闭环 --"
say "  清场：compose down -v、删除字节目录与备份"
dc down -v --remove-orphans >> "${SUMMARY}" 2>&1
rm -rf "${BLOBS}" "${BLOBS_ALT}" "${BLOBS_BAK}" "${BACKUP_DIR}"
mkdir -p "${BLOBS}" "${BACKUP_DIR}"

say "  图像构建：cangshu-m1:local"
dc build app >> "${SUMMARY}" 2>&1 || { say "镜像构建失败，见 ${SUMMARY}"; exit 1; }

say "  1) 起数据库容器（PG17 ＋ named volume cangshu-pgdata ＋ 固定 collation）"
dc up -d db >> "${SUMMARY}" 2>&1
if ! wait_db_healthy; then say "  库容器未就绪；日志尾部："; dc logs --tail 20 db | tee -a "${SUMMARY}"; exit 1; fi
check "$(q "SHOW server_version" | cut -d. -f1)" "17" "PG 大版本为 17（两轨一致项①）"
check "$(q "SELECT datcollate FROM pg_database WHERE datname = '${DB_NAME}'")" "C.UTF-8" "交付态 collation 固定为 C.UTF-8"
check "$(q "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'cangshu_m1'")" "0" "起库后表尚未建（应用绝不自己建表）"
check "$("${DOCKER}" volume inspect cangshu-pgdata --format '{{.Name}}' 2>/dev/null)" "cangshu-pgdata" "PG 数据在 named volume cangshu-pgdata"

say "  2) 人工执行迁移（scripts/compose-migrate.sh；DDL 与记账同事务）"
bash "${ROOT_DIR}/scripts/compose-migrate.sh" >> "${SUMMARY}" 2>&1 || { say "迁移失败，见 ${SUMMARY}"; exit 1; }
check "$(q "SELECT count(*) FROM cangshu_m1.schema_version")" "2" "台账登记两版（V1／V2）"
check "$(q "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'cangshu_m1'")" "5" "五表已由脚本建出"

say "  3) 起应用（启动先做对账，04 §8 步骤 3）"
dc up -d app >> "${SUMMARY}" 2>&1
if ! wait_health 90; then say "  应用未就绪；日志尾部："; app_log 20 | tee -a "${SUMMARY}"; exit 1; fi
say "  应用启动日志："; app_log 4 | sed 's/^/    /' | tee -a "${SUMMARY}"

SAMPLE="${LOG_DIR}/u5-sample.txt"
printf '仓鼠 U5 交付态样本 %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" > "${SAMPLE}"
SAMPLE_SHA="$(sha_of "${SAMPLE}")"
UP=$(curl -sS -o "$(win_path "${LOG_DIR}/body-upload.out")" -w '%{http_code}' \
  -F "file=@$(win_path "${SAMPLE}");type=text/plain;filename=U5交付样本.txt" "${BASE}/api/resources")
check "${UP}" "201" "POST /api/resources（交付态上传）"
DIGEST="$(json_str digest "${LOG_DIR}/body-upload.out")"
RES_ID="$(json_str id "${LOG_DIR}/body-upload.out")"
curl -sS -o "$(win_path "${LOG_DIR}/body-list.out")" "${BASE}/api/resources?page=1&size=20"
check "$(json_num total "${LOG_DIR}/body-list.out")" "1" "列表可查"
check "$(http_status "${BASE}/api/resources/${RES_ID}")" "200" "详情可读"
curl -sS -o "$(win_path "${LOG_DIR}/downloaded.bin")" "${BASE}/api/resources/${RES_ID}/content"
check "$(sha_of "${LOG_DIR}/downloaded.bin")" "${SAMPLE_SHA}" "下载字节与上传一致"
check "$([ -f "$(blob_path "${BLOBS}" "${DIGEST}")" ] && echo yes || echo no)" "yes" "字节落在宿主 bind mount cangshu-blobs"
KEY_BEFORE="$(q "SELECT storage_key FROM cangshu_m1.location LIMIT 1")"

# ────────────────────────── ② 重启 ──────────────────────────
say ""
say "-- ② 重启：重启应用后数据仍可定位 --"
dc restart app >> "${SUMMARY}" 2>&1
if ! wait_health 90; then say "  重启后未就绪"; app_log 20 | tee -a "${SUMMARY}"; exit 1; fi
curl -sS -o "$(win_path "${LOG_DIR}/body-list2.out")" "${BASE}/api/resources?page=1&size=20"
check "$(json_num total "${LOG_DIR}/body-list2.out")" "1" "重启后列表仍有该资源"
curl -sS -o "$(win_path "${LOG_DIR}/downloaded2.bin")" "${BASE}/api/resources/${RES_ID}/content"
check "$(sha_of "${LOG_DIR}/downloaded2.bin")" "${SAMPLE_SHA}" "重启后下载字节仍一致"
check "$(q "SELECT count(*) FROM cangshu_m1.schema_version")" "2" "重启后台账未变"

# ────────────────────────── ③ 新卷恢复 ──────────────────────────
say ""
say "-- ③ 新卷恢复：同批备份（PG 逻辑备份 ＋ 字节复制）→ 删卷删字节 → 恢复 --"
dc exec -T db pg_dump -U "${DB_USER}" -d "${DB_NAME}" > "${BACKUP_DIR}/cangshu-pgdump.sql" 2>>"${SUMMARY}" \
  || { say "pg_dump 失败"; exit 1; }
cp -r "${BLOBS}" "${BLOBS_BAK}"
check "$([ -s "${BACKUP_DIR}/cangshu-pgdump.sql" ] && echo yes || echo no)" "yes" "PG 逻辑备份已产出"
check "$([ -f "$(blob_path "${BLOBS_BAK}" "${DIGEST}")" ] && echo yes || echo no)" "yes" "字节已同批复制"

dc down -v --remove-orphans >> "${SUMMARY}" 2>&1
rm -rf "${BLOBS}"
check "$("${DOCKER}" volume ls -q --filter name=^cangshu-pgdata$ | wc -l | tr -d ' ')" "0" "PG 卷已删除"
check "$([ -d "${BLOBS}" ] && echo yes || echo no)" "no" "字节目录已删除"

dc up -d db >> "${SUMMARY}" 2>&1
if ! wait_db_healthy; then say "  新卷起库失败"; exit 1; fi
check "$(q "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'cangshu_m1'")" "0" "新卷是空库（禁空库降级的起点）"
dc exec -T db psql -U "${DB_USER}" -d "${DB_NAME}" -q -v ON_ERROR_STOP=1 -f - \
  < "${BACKUP_DIR}/cangshu-pgdump.sql" >> "${SUMMARY}" 2>&1 || { say "恢复失败"; exit 1; }
cp -r "${BLOBS_BAK}" "${BLOBS}"
check "$(q "SELECT count(*) FROM cangshu_m1.schema_version")" "2" "台账已随备份恢复"
check "$(q "SELECT count(*) FROM cangshu_m1.resource")" "1" "资源行已随备份恢复"
check "$([ -f "$(blob_path "${BLOBS}" "${DIGEST}")" ] && echo yes || echo no)" "yes" "字节已从备份恢复"

dc up -d app >> "${SUMMARY}" 2>&1
if ! wait_health 90; then say "  恢复后应用未就绪"; app_log 20 | tee -a "${SUMMARY}"; exit 1; fi
curl -sS -o "$(win_path "${LOG_DIR}/body-list3.out")" "${BASE}/api/resources?page=1&size=20"
check "$(json_num total "${LOG_DIR}/body-list3.out")" "1" "恢复后列表可见该资源"
curl -sS -o "$(win_path "${LOG_DIR}/downloaded3.bin")" "${BASE}/api/resources/${RES_ID}/content"
check "$(sha_of "${LOG_DIR}/downloaded3.bin")" "${SAMPLE_SHA}" "恢复后下载字节一致（资源仍可定位）"

# ────────────────────────── ④ 更换字节根 ──────────────────────────
say ""
say "-- ④ 更换字节根：复制字节 ＋ 只改根配置 ＋ 相对存储键不变 --"
dc stop app >> "${SUMMARY}" 2>&1
cp -r "${BLOBS}" "${BLOBS_ALT}"
check "$([ -f "$(blob_path "${BLOBS_ALT}" "${DIGEST}")" ] && echo yes || echo no)" "yes" "字节已复制到新根"
CANGSHU_BLOBS_DIR="./cangshu-blobs-alt" dc up -d app >> "${SUMMARY}" 2>&1
if ! wait_health 90; then say "  换根后应用未就绪"; app_log 20 | tee -a "${SUMMARY}"; exit 1; fi
check "$(q "SELECT storage_key FROM cangshu_m1.location LIMIT 1")" "${KEY_BEFORE}" "换根后相对存储键不变"
curl -sS -o "$(win_path "${LOG_DIR}/body-list4.out")" "${BASE}/api/resources?page=1&size=20"
check "$(json_num total "${LOG_DIR}/body-list4.out")" "1" "换根后列表可见该资源"
curl -sS -o "$(win_path "${LOG_DIR}/downloaded4.bin")" "${BASE}/api/resources/${RES_ID}/content"
check "$(sha_of "${LOG_DIR}/downloaded4.bin")" "${SAMPLE_SHA}" "换根后下载字节一致（资源仍可定位）"
check "$(q "SELECT count(*) FROM cangshu_m1.resource")" "1" "换根不动数据库"

say ""
say "-- 收尾：停应用（保留库与卷，供人工复核）--"
dc stop app >> "${SUMMARY}" 2>&1

say ""
say "== 汇总：通过 ${PASS} ｜ 不符 ${FAIL} =="
say "结构化摘要：${SUMMARY}"
say "备份件：${BACKUP_DIR}/cangshu-pgdump.sql ｜ 字节备份 ${BLOBS_BAK} ｜ 新根 ${BLOBS_ALT}"
if [ "${FAIL}" -ne 0 ]; then
  say "结论：有观测项与 07 §3／08 §1 ACC-G6 的预期不符，需排查（见上方 [FAIL]）。"
  exit 1
fi
say "结论：初始化（起库→人工迁移→起应用→端到端闭环）、重启、新卷恢复（同批备份）、更换字节根四项"
say "      在 Compose 交付环境逐项通过；PG 数据在 named volume、字节在独立 bind mount，两卷分离。"
