#!/usr/bin/env bash
set -euo pipefail
# Connection/authentication come from libpq configuration; never print credentials.
root=$(cd "$(dirname "$0")" && pwd)
database=${1:?Usage: bash backend/migrate.sh DATABASE [001|002|003|004|005|006|007|008|009|010]}
target=${2:-010}
[[ "$target" =~ ^(00[1-9]|010)$ ]] || { echo 'Unknown migration target' >&2; exit 1; }
command -v psql >/dev/null || { echo 'PostgreSQL 15 psql is required' >&2; exit 1; }
sql=$(mktemp)
trap 'rm -f "$sql"' EXIT
cat > "$sql" <<'SQL'
SELECT pg_advisory_xact_lock(708008);
CREATE SCHEMA IF NOT EXISTS migration_meta;
REVOKE ALL ON SCHEMA migration_meta FROM PUBLIC;
CREATE TABLE IF NOT EXISTS migration_meta.versions (
    version text PRIMARY KEY, checksum text NOT NULL, applied_at timestamptz NOT NULL DEFAULT now()
);
SQL
for path in "$root"/migrations/*.sql; do
    name=$(basename "$path")
    version=${name%%_*}
    [[ "$version" > "$target" ]] && continue
    if command -v sha256sum >/dev/null; then
        digest=$(sha256sum "$path")
    else
        digest=$(shasum -a 256 "$path")
    fi
    digest=${digest%% *}
    cat >> "$sql" <<SQL
DO \$\$ BEGIN
    IF EXISTS (SELECT 1 FROM migration_meta.versions WHERE version = '$version' AND checksum <> '$digest') THEN
        RAISE EXCEPTION 'Applied migration $version has changed';
    END IF;
END \$\$;
SELECT NOT EXISTS (SELECT 1 FROM migration_meta.versions WHERE version = '$version') AS apply_migration \gset
\if :apply_migration
SQL
    cat "$path" >> "$sql"
    cat >> "$sql" <<SQL
INSERT INTO migration_meta.versions(version, checksum) VALUES ('$version', '$digest');
\endif
SQL
done
psql -X --dbname="$database" --set=ON_ERROR_STOP=1 --single-transaction --file="$sql"
