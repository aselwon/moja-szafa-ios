#!/usr/bin/env bash
# Requires local/disposable PostgreSQL 15+ and PG* connection settings.
# Never uses or drops the database named in PGDATABASE.
set -euo pipefail
cd "$(dirname "$0")/.."
for tool in psql createdb dropdb; do
  command -v "$tool" >/dev/null || { echo "Missing $tool; install nothing automatically." >&2; exit 1; }
done
prefix="szafa_t008_${$}_${RANDOM}"
databases=()
cleanup() {
  for database in "${databases[@]}"; do dropdb --if-exists "$database"; done
}
trap cleanup EXIT
run_sql() {
  psql -X --dbname "$database" --set ON_ERROR_STOP=1 --file "$1" >/dev/null
}
for scenario in fresh upgrade; do
  database="${prefix}_${scenario}"
  createdb "$database"
  databases+=("$database")
  run_sql backend/tests/bootstrap.sql
  run_sql backend/migrations/0001_wardrobe.sql
  if [[ "$scenario" == upgrade ]]; then run_sql backend/tests/previous-version.sql; fi
  run_sql backend/migrations/0002_product.sql
  if [[ "$scenario" == upgrade ]]; then run_sql backend/tests/upgrade.sql; fi
  run_sql backend/tests/contracts.sql
  echo "PASS: PostgreSQL $scenario migration and domain/security contracts"
done
