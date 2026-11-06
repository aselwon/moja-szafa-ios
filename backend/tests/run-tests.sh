#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
# Independently verify that the runner applied every checked-in migration.
# Derive this from files, not migrate.sh's default target or a hand-edited total.
migration_files=("$root"/migrations/[0-9][0-9][0-9]_*.sql)
[[ -f "${migration_files[0]}" ]] || { echo "No migrations found" >&2; exit 1; }
expected_migration_count=${#migration_files[@]}
for tool in psql createdb dropdb pg_dump; do
    command -v "$tool" >/dev/null || { echo "Required PostgreSQL 15 tool missing: $tool" >&2; exit 1; }
done
prefix="wardrobe_t008_${$}_${RANDOM}"
fresh="${prefix}_fresh"
upgrade="${prefix}_upgrade"
rollback="${prefix}_rollback"
artifacts=$(mktemp -d)
cleanup() {
    dropdb --if-exists "$fresh"
    dropdb --if-exists "$upgrade"
    dropdb --if-exists "$rollback"
    rm -rf "$artifacts"
}
trap cleanup EXIT
for database in "$fresh" "$upgrade" "$rollback"; do
    createdb "$database"
    psql -X -v ON_ERROR_STOP=1 -d "$database" -f "$root/tests/bootstrap.sql"
done
# A migration failing after its DDL must leave no partial schema or ledger entry.
bash "$root/migrate.sh" "$rollback" 001
mkdir -p "$artifacts/broken/migrations"
cp "$root/migrate.sh" "$artifacts/broken/"
cp "$root"/migrations/*.sql "$artifacts/broken/migrations/"
cat >> "$artifacts/broken/migrations/002_wardrobe.sql" <<'SQL'
DO $$ BEGIN RAISE EXCEPTION 'injected migration failure'; END $$;
SQL
if bash "$artifacts/broken/migrate.sh" "$rollback" > "$artifacts/rollback.log" 2>&1; then
    echo 'Expected injected migration failure' >&2; exit 1
fi
grep -q 'injected migration failure' "$artifacts/rollback.log"
psql -X -v ON_ERROR_STOP=1 -d "$rollback" <<'SQL'
DO $$ BEGIN
    IF to_regclass('app.garments') IS NOT NULL OR (SELECT count(*) FROM migration_meta.versions) <> 1 THEN
        RAISE EXCEPTION 'Failed migration was not rolled back';
    END IF;
END $$;
SQL
bash "$root/migrate.sh" "$rollback"
psql -X -v ON_ERROR_STOP=1 -d "$rollback" -v expected_migration_count="$expected_migration_count" -f "$root/tests/schema.sql"
bash "$root/migrate.sh" "$fresh"
bash "$root/migrate.sh" "$upgrade" 001
psql -X -v ON_ERROR_STOP=1 -d "$upgrade" -f "$root/tests/previous-version.sql"
bash "$root/migrate.sh" "$upgrade" 002
psql -X -v ON_ERROR_STOP=1 -d "$upgrade" <<'SQL'
INSERT INTO app.garments(user_id,name,category,price_grosz)
SELECT user_id,'v002 garment','top',12345 FROM app.profiles WHERE display_name = 'Upgrade fixture';
SQL
bash "$root/migrate.sh" "$upgrade" 003
bash "$root/migrate.sh" "$upgrade"
psql -X -v ON_ERROR_STOP=1 -d "$upgrade" <<'SQL'
DO $$ BEGIN
    IF NOT EXISTS (SELECT FROM app.profiles WHERE display_name = 'Upgrade fixture' AND language = 'en' AND city = 'Warsaw' AND version = 1) THEN
        RAISE EXCEPTION 'Upgrade lost or changed existing data';
    END IF;
    IF NOT EXISTS (SELECT FROM app.garments WHERE name = 'v002 garment' AND price_grosz = 12345 AND version = 1) THEN
        RAISE EXCEPTION 'v003 lost v002 garment';
    END IF;
END $$;
SQL
for database in "$fresh" "$upgrade"; do
    # Replay must skip applied migrations, not recreate tables or change data.
    bash "$root/migrate.sh" "$database"
    psql -X -v ON_ERROR_STOP=1 -d "$database" -v expected_migration_count="$expected_migration_count" -f "$root/tests/schema.sql"
    psql -X -v ON_ERROR_STOP=1 -d "$database" -f "$root/tests/api.sql"
    psql -X -v ON_ERROR_STOP=1 -d "$database" -f "$root/tests/import-metadata.sql"
    psql -X -v ON_ERROR_STOP=1 -d "$database" -f "$root/tests/garment-edit.sql"
    psql -X -v ON_ERROR_STOP=1 -d "$database" -f "$root/tests/wardrobe.sql"
    psql -X -v ON_ERROR_STOP=1 -d "$database" -f "$root/tests/garment-deletion.sql"
    psql -X -v ON_ERROR_STOP=1 -d "$database" -f "$root/tests/outfits.sql"
    psql -X -v ON_ERROR_STOP=1 -d "$database" -f "$root/tests/planner.sql"
    bash "$root/tests/planner-concurrency.sh" "$database"
    psql -X -v ON_ERROR_STOP=1 -d "$database" -f "$root/tests/trips.sql"
    bash "$root/tests/trips-concurrency.sh" "$database"
    psql -X -v ON_ERROR_STOP=1 -d "$database" -f "$root/tests/offline-sync.sql"
    psql -X -v ON_ERROR_STOP=1 -d "$database" -f "$root/tests/wear-editing.sql"
    psql -X -v ON_ERROR_STOP=1 -d "$database" -f "$root/tests/initial-wear-history.sql"
    psql -X -v ON_ERROR_STOP=1 -d "$database" -f "$root/tests/personalization.sql"
    psql -X -v ON_ERROR_STOP=1 -d "$database" -f "$root/tests/wear-history.sql"
    bash "$root/tests/api-concurrency.sh" "$database"
    bash "$root/tests/wear-concurrency.sh" "$database"
    # Explicit synthetic policy; production migration remains disabled by default.
    psql -X -v ON_ERROR_STOP=1 -d "$database" -c "UPDATE api_private.ai_policy SET enabled=true,image_enabled=true,daily_user_units=1000000,daily_global_units=1000000"
    psql -X -v ON_ERROR_STOP=1 -d "$database" -f "$root/tests/jobs.sql"
    psql -X -v ON_ERROR_STOP=1 -d "$database" -f "$root/tests/consent.sql"
    psql -X -v ON_ERROR_STOP=1 -d "$database" -f "$root/tests/images.sql"
    psql -X -v ON_ERROR_STOP=1 -d "$database" -f "$root/tests/recognition-drafts.sql"
    psql -X -v ON_ERROR_STOP=1 -d "$database" -f "$root/tests/exports.sql"
    psql -X -v ON_ERROR_STOP=1 -d "$database" -f "$root/tests/deletion.sql"
    psql -X -v ON_ERROR_STOP=1 -d "$database" -f "$root/tests/suggestions.sql"
    psql -X -v ON_ERROR_STOP=1 -d "$database" -f "$root/tests/purchases.sql"
    bash "$root/tests/purchase-concurrency.sh" "$database"
    bash "$root/tests/purchase-sweep-race.sh" "$database"
    bash "$root/tests/jobs-concurrency.sh" "$database"
    psql -X -v ON_ERROR_STOP=1 -d "$database" -f "$root/tests/ai-runtime.sql"
    psql -X -v ON_ERROR_STOP=1 -d "$database" -f "$root/tests/telemetry.sql"
    psql -X -v ON_ERROR_STOP=1 -d "$database" -f "$root/tests/telemetry-gateway.sql"
    psql -X -v ON_ERROR_STOP=1 -d "$database" -f "$root/tests/operations.sql"
    psql -X -v ON_ERROR_STOP=1 -d "$database" -f "$root/tests/apple-subscriptions.sql"
    psql -X -v ON_ERROR_STOP=1 -d "$database" -f "$root/tests/observability-report.sql"
    psql -X -v ON_ERROR_STOP=1 -d "$database" -f "$root/tests/weather-admission.sql"
    bash "$root/tests/ai-runtime-concurrency.sh" "$database"
    # PostgreSQL clients may emit a randomly generated \restrict token.
    pg_dump --schema-only --schema=app --schema=api_private --no-owner --no-privileges "$database" | sed '/^\\restrict /d; /^\\unrestrict /d' > "$artifacts/${database}.sql"
done
diff -u "$artifacts/${fresh}.sql" "$artifacts/${upgrade}.sql"
# Corrupt only a disposable database's ledger: never modify a migration file.
psql -X -v ON_ERROR_STOP=1 -d "$fresh" -c "UPDATE migration_meta.versions SET checksum = 'invalid' WHERE version = '001'"
if bash "$root/migrate.sh" "$fresh" > "$artifacts/checksum.log" 2>&1; then
    echo 'Expected checksum mismatch to fail' >&2; exit 1
fi
grep -q 'Applied migration 001 has changed' "$artifacts/checksum.log"
echo 'PASS: clean install, populated v001 upgrade, replay, atomic rollback, checksum and schema/security contracts'

# T055: isolated synthetic database + object restore and post-snapshot deletions.
bash "$root/tests/recovery-drill.sh"

AI_DEPLOYMENT_PG_TESTS=1 bash "$root/tests/ai-worker-deployment.sh"
