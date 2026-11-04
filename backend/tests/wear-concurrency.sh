#!/usr/bin/env bash
set -euo pipefail
database=${1:?Disposable test database required}
artifacts=$(mktemp -d)
trap 'rm -rf "$artifacts"' EXIT
psql -X -v ON_ERROR_STOP=1 -d "$database" <<'SQL'
INSERT INTO auth.users VALUES ('00000000-0000-0000-0000-000000000097');
INSERT INTO app.profiles(id,user_id) VALUES ('00000000-0000-0000-0000-000000000097','00000000-0000-0000-0000-000000000097');
INSERT INTO app.garments(id,user_id,name,category) VALUES ('00000000-0000-0000-0000-000000000097','00000000-0000-0000-0000-000000000097','Concurrent wear','top');
SQL
cat > "$artifacts/create.sql" <<'SQL'
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000097',true);
SELECT app.api_v1_save_wear('{"operationID":"00000000-0000-0000-0000-000000000097","wear":{"id":"00000000-0000-0000-0000-000000000097","version":0,"deleted":false,"wornOn":"2026-01-01","timezone":"Europe/Warsaw","garmentIDs":["00000000-0000-0000-0000-000000000097"]}}');
SELECT pg_sleep(1);
COMMIT;
SQL
psql -X -At -v ON_ERROR_STOP=1 -d "$database" -f "$artifacts/create.sql" > "$artifacts/a" &
first=$!
psql -X -At -v ON_ERROR_STOP=1 -d "$database" -f "$artifacts/create.sql" > "$artifacts/b" &
second=$!
wait "$first"
wait "$second"
diff -u "$artifacts/a" "$artifacts/b"
# Different operation keys edit the same acknowledged version concurrently.
cat > "$artifacts/edit.sql" <<'SQL'
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000097',true);
SELECT app.api_v1_save_wear(jsonb_build_object('operationID',gen_random_uuid(),'wear',
    '{"id":"00000000-0000-0000-0000-000000000097","version":1,"deleted":false,"wornOn":"2026-01-02","timezone":"Europe/Warsaw","garmentIDs":["00000000-0000-0000-0000-000000000097"]}'::jsonb));
SELECT pg_sleep(1);
COMMIT;
SQL
psql -X -At -v ON_ERROR_STOP=1 -d "$database" -f "$artifacts/edit.sql" > "$artifacts/a" &
first=$!
psql -X -At -v ON_ERROR_STOP=1 -d "$database" -f "$artifacts/edit.sql" > "$artifacts/b" &
second=$!
wait "$first"
wait "$second"
# Exactly one editor wins. A hidden internal error must not pass as a conflict.
if grep -q '"data"' "$artifacts/a"; then
    grep -q '"version_conflict"' "$artifacts/b"
else
    grep -q '"version_conflict"' "$artifacts/a"
    grep -q '"data"' "$artifacts/b"
fi
psql -X -v ON_ERROR_STOP=1 -d "$database" <<'SQL'
DO $$ BEGIN
    IF (SELECT count(*) FROM app.wear_events WHERE user_id = '00000000-0000-0000-0000-000000000097') <> 1
       OR (SELECT version FROM app.wear_events WHERE id = '00000000-0000-0000-0000-000000000097') <> 2
       OR (SELECT count(*) FROM app.wear_event_items WHERE user_id = '00000000-0000-0000-0000-000000000097') <> 1
       OR (SELECT count(*) FROM api_private.mutations WHERE user_id = '00000000-0000-0000-0000-000000000097') <> 2 THEN
        RAISE EXCEPTION 'Concurrent wear writes duplicated or lost state';
    END IF;
END $$;
DELETE FROM auth.users WHERE id = '00000000-0000-0000-0000-000000000097';
SQL
