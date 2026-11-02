#!/usr/bin/env bash
set -euo pipefail
database=${1:?Disposable test database required}
artifacts=$(mktemp -d)
trap 'rm -rf "$artifacts"' EXIT
psql -X -v ON_ERROR_STOP=1 -d "$database" <<'SQL'
INSERT INTO auth.users VALUES ('00000000-0000-0000-0000-000000000099');
INSERT INTO app.profiles(id,user_id) VALUES ('00000000-0000-0000-0000-000000000099','00000000-0000-0000-0000-000000000099');
SQL
cat > "$artifacts/request.sql" <<'SQL'
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000099',true);
SELECT app.api_v1_save_garment('{"operation_id":"00000000-0000-0000-0000-000000000099","garment_id":"00000000-0000-0000-0000-000000000099","base_version":null,"garment":{"name":"Concurrent","category":"top","price_grosz":0,"availability":"available"}}');
SELECT pg_sleep(1);
COMMIT;
SQL
# Two independent connections race the same key. Both must succeed.
psql -X -At -v ON_ERROR_STOP=1 -d "$database" -f "$artifacts/request.sql" > "$artifacts/a" &
first=$!
psql -X -At -v ON_ERROR_STOP=1 -d "$database" -f "$artifacts/request.sql" > "$artifacts/b" &
second=$!
wait "$first"
wait "$second"
diff -u "$artifacts/a" "$artifacts/b"
# A third connection retries AFTER commit: models a lost HTTP response/restart.
psql -X -At -v ON_ERROR_STOP=1 -d "$database" -f "$artifacts/request.sql" > "$artifacts/c"
diff -u "$artifacts/a" "$artifacts/c"
psql -X -v ON_ERROR_STOP=1 -d "$database" <<'SQL'
DO $$ BEGIN
    IF (SELECT count(*) FROM app.garments WHERE user_id = '00000000-0000-0000-0000-000000000099') <> 1
       OR (SELECT version FROM app.garments WHERE id = '00000000-0000-0000-0000-000000000099') <> 1
       OR (SELECT count(*) FROM api_private.mutations WHERE user_id = '00000000-0000-0000-0000-000000000099') <> 1 THEN
        RAISE EXCEPTION 'Concurrent retry duplicated or changed the record';
    END IF;
END $$;
DELETE FROM auth.users WHERE id = '00000000-0000-0000-0000-000000000099';
SQL
