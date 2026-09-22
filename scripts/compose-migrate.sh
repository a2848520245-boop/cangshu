#!/usr/bin/env bash
# 仓鼠 M1 交付态：人工执行迁移（07-运行手册 §3 初始化顺序第 2 步 ＋ §4）
#
# 用法：
#   bash scripts/compose-migrate.sh
#
# 前置：db 容器已起且健康（docker compose up -d db）。
#
# 职责边界：本脚本只负责「容器传输」这一段（docker compose exec -T db psql）。锁协议、
# 脚本 SHA-256 记账、DDL 与 schema_version 记账同一事务、只增不改与失败回滚，全部由
# scripts/migrate.sh ＋ scripts/lib/migration-lock.sh 唯一实现，两轨（本机／容器）共用同一实现
# （07 §3 两轨一致项②：DDL 与迁移语义两轨一致）。
#
# 锁协议（07 §1／§4／§7）：改动目标库之前先取**迁移锁（键 20260918）**与**写者锁（键 20260919）**，
# 两把都是非阻塞取锁；取不到即拒绝并**不写任何字节**，退出码 2：
#   - 迁移锁被持有 ＝ 已有迁移在执行；
#   - 写者锁被持有 ＝ serve／CLI 写者还在跑（迁移操作需确保业务写者已退出）。
# 退出码表与设计说明见 tools/migration-gate/README.md「人工迁移锁」。
#
# 说明：本脚本是「人工执行」这一步的可复现命令，不改变「由人发起」这一点；
#      也不会被应用或 compose 自动调用。

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

DB_NAME="${CANGSHU_DB_NAME:-cangshu}"
DB_USER="${CANGSHU_DB_USER:-postgres}"

# 本机 docker 不在 PATH；凭据助手（docker-credential-desktop.exe）与 docker.exe 同目录，
# 把 Docker 的 bin 目录并入 PATH 才能解析 helper（否则拉镜像报 error getting credentials）。
DOCKER_BIN_DIR="/c/Program Files/Docker/Docker/resources/bin"
if [ -d "$DOCKER_BIN_DIR" ] && ! command -v docker >/dev/null 2>&1; then
  export PATH="$DOCKER_BIN_DIR:$PATH"
fi
DOCKER="${DOCKER:-docker}"

echo "== 人工迁移（交付态：容器内 psql）=="
# 传输命令：默认 docker compose exec；CANGSHU_MIGRATE_PSQL 只在取证／排障时替换传输（协议与编排不变）。
export CANGSHU_MIGRATE_PSQL="${CANGSHU_MIGRATE_PSQL:-$DOCKER compose exec -T db psql -U $DB_USER -d $DB_NAME}"
export CANGSHU_DB_NAME="$DB_NAME"
exec bash "$ROOT_DIR/scripts/migrate.sh"
