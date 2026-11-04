#!/usr/bin/env bash
set -euo pipefail
database=${1:?Disposable test database required}
artifacts=$(mktemp -d)
trap 'rm -rf "$artifacts"' EXIT
psql -X -v ON_ERROR_STOP=1 -d "$database" <<'SQL'
INSERT INTO auth.users VALUES ('00000000-0000-0000-0000-000000004343');
INSERT INTO app.profiles(id,user_id) VALUES ('00000000-0000-0000-0000-000000004343','00000000-0000-0000-0000-000000004343');
INSERT INTO app.garments(id,user_id,name,category) VALUES ('10000000-0000-0000-0000-000000004343','00000000-0000-0000-0000-000000004343','Packed shirt','top');
INSERT INTO app.trips(id,user_id,destination,starts_on,ends_on) VALUES ('30000000-0000-0000-0000-000000004343','00000000-0000-0000-0000-000000004343','Warsaw',current_date,current_date);
INSERT INTO app.trip_items(user_id,trip_id,garment_id) VALUES ('00000000-0000-0000-0000-000000004343','30000000-0000-0000-0000-000000004343','10000000-0000-0000-0000-000000004343');
SQL
cat > "$artifacts/pack.sql" <<'SQL'
BEGIN;
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claim.sub='00000000-0000-0000-0000-000000004343';
SELECT app.api_v1_trips('{"action":"pack","operationID":"40000000-0000-0000-0000-000000004343","id":"30000000-0000-0000-0000-000000004343","baseVersion":1,"garmentID":"10000000-0000-0000-0000-000000004343","packed":true}');
SELECT pg_sleep(0.2);
COMMIT;
SQL
pids=()
for i in 1 2 3 4; do
 psql -X -At -v ON_ERROR_STOP=1 -d "$database" -f "$artifacts/pack.sql" > "$artifacts/$i" &
 pids+=("$!")
done
for pid in "${pids[@]}"; do wait "$pid"; done
for i in 2 3 4; do diff -u "$artifacts/1" "$artifacts/$i"; done
if grep -q '"error"' "$artifacts/1"; then cat "$artifacts/1"; exit 1; fi
psql -X -v ON_ERROR_STOP=1 -d "$database" <<'SQL'
DO $$ BEGIN
 IF (SELECT version FROM app.trips WHERE id='30000000-0000-0000-0000-000000004343')<>2
 OR (SELECT packed FROM app.trip_items WHERE user_id='00000000-0000-0000-0000-000000004343') IS DISTINCT FROM true
 OR EXISTS(SELECT FROM app.wear_events WHERE user_id='00000000-0000-0000-0000-000000004343') THEN
 RAISE EXCEPTION 'Concurrent packing replay mutated twice or wrote wear'; END IF;
END $$;
DELETE FROM auth.users WHERE id='00000000-0000-0000-0000-000000004343';
SQL
