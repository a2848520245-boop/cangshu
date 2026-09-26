#!/usr/bin/env bash
set -euo pipefail

# Only the explicitly requested, ephemeral GitHub-hosted PostgreSQL service may be initialized here.
case "${GITHUB_REPOSITORY:-}" in
  a2848520245-boop/cangshu|a2848520245-boop/cangshu-private-backup) ;;
  *) echo 'Refusing database setup outside the two CangShu repositories' >&2; exit 2 ;;
esac
[[ "${GITHUB_ACTIONS:-}" == true && "${GITHUB_EVENT_NAME:-}" == workflow_dispatch &&
   "${CANGSHU_CI_REAL_E2E:-}" == run-real-e2e ]] || {
  echo 'Real E2E requires an explicit manual GitHub Actions request' >&2; exit 2;
}
[[ "${CI_PG_PORT:-}" == 15439 && -n "${CI_PG_CONTAINER_ID:-}" ]] || {
  echo 'Expected isolated PostgreSQL service on loopback port 15439' >&2; exit 2;
}
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"
docker inspect --format '{{.State.Running}}' "$CI_PG_CONTAINER_ID" | grep -qx true

docker exec "$CI_PG_CONTAINER_ID" createdb -U postgres cangshu_ui_ci
for database in cangshu_test cangshu_ui_ci; do
  for script in db/migration/V1__init.sql db/migration/V2__search_indexes.sql; do
    sha="$(sha256sum "$script")"
    sha="${sha%% *}"
    docker exec -i "$CI_PG_CONTAINER_ID" psql -X -q -v ON_ERROR_STOP=1 \
      -v "script_sha256=$sha" -U postgres -d "$database" < "$script"
  done
  echo "Migrated isolated database $database with source SHA-256 ledger"
done
