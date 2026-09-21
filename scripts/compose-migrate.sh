#!/usr/bin/env bash
# 仓鼠 M1 交付态：人工执行迁移（07-运行手册 §3 初始化顺序第 2 步 ＋ §4）
#
# 用法：
#   bash scripts/compose-migrate.sh
#
# 前置：db 容器已起且健康（`docker compose up -d db`）。
#
# 语义与开发态逐条一致（07 §3 两轨一致项②）：
#   - 脚本目录 db/migration/，只增不改；
#   - 人工发起，**应用绝不自动改表**；
#   - DDL 与 `schema_version` 记账同一事务，出错整体回滚（脚本内部 BEGIN/COMMIT）；
#   - 每个脚本带 `-v ON_ERROR_STOP=1 -v script_sha256=<脚本 SHA-256>`，台账记录的摘要
#     即宿主上该文件的摘要（脚本经 stdin 送入容器，规避容器内外路径差异）。
#
# 说明：本脚本是「人工执行」这一步的**可复现命令**，不改变「由人发起」这一点；
#      也不会被应用或 compose 自动调用。

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "${ROOT_DIR}"

DB_NAME="${CANGSHU_DB_NAME:-cangshu}"
DB_USER="${CANGSHU_DB_USER:-postgres}"

# 本机 docker 不在 PATH；凭据助手（docker-credential-desktop.exe）与 docker.exe 同目录，
# 把 Docker 的 bin 目录并入 PATH 才能解析 helper（否则拉镜像报 error getting credentials）。
DOCKER_BIN_DIR="/c/Program Files/Docker/Docker/resources/bin"
if [ -d "${DOCKER_BIN_DIR}" ] && ! command -v docker >/dev/null 2>&1; then
  export PATH="${DOCKER_BIN_DIR}:${PATH}"
fi
DOCKER="${DOCKER:-docker}"

echo "== 人工迁移：库 ${DB_NAME}（容器内 psql）=="
for script in db/migration/V*.sql; do
  sha="$(sha256sum "${script}" | cut -d' ' -f1)"
  printf '  执行 %s（sha256=%s…）\n' "$(basename "${script}")" "${sha:0:12}"
  "${DOCKER}" compose exec -T db psql -U "${DB_USER}" -d "${DB_NAME}" -q \
    -v ON_ERROR_STOP=1 -v "script_sha256=${sha}" -f - < "${script}"
done

echo "  台账："
"${DOCKER}" compose exec -T db psql -U "${DB_USER}" -d "${DB_NAME}" -tAc \
  "SELECT version || ' | ' || script_name || ' | ' || script_sha256 FROM cangshu_m1.schema_version ORDER BY version" \
  | sed 's/^/    /'
echo "== 迁移完成；应用可以起了（docker compose up -d app）=="
