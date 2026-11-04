#!/usr/bin/env bash
set -euo pipefail
database=${1:?Disposable test database required}
artifacts=$(mktemp -d)
trap 'rm -rf "$artifacts"' EXIT
psql -X -v ON_ERROR_STOP=1 -d "$database" <<'SQL'
INSERT INTO auth.users VALUES ('00000000-0000-0000-0000-000000004141');
INSERT INTO app.profiles(id,user_id) VALUES ('00000000-0000-0000-0000-000000004141','00000000-0000-0000-0000-000000004141');
INSERT INTO app.garments(id,user_id,name,category) VALUES ('10000000-0000-0000-0000-000000004141','00000000-0000-0000-0000-000000004141','Concurrent shirt','top');
INSERT INTO app.outfits(id,user_id,name) VALUES ('20000000-0000-0000-0000-000000004141','00000000-0000-0000-0000-000000004141','Concurrent outfit');
INSERT INTO app.outfit_items(user_id,outfit_id,garment_id,position) VALUES ('00000000-0000-0000-0000-000000004141','20000000-0000-0000-0000-000000004141','10000000-0000-0000-0000-000000004141',0);
INSERT INTO app.planned_outfits(id,user_id,outfit_id,planned_on,timezone) VALUES ('30000000-0000-0000-0000-000000004141','00000000-0000-0000-0000-000000004141','20000000-0000-0000-0000-000000004141',(clock_timestamp() AT TIME ZONE 'UTC')::date,'UTC');
SQL
cat > "$artifacts/confirm.sql" <<'SQL'
BEGIN;
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claim.sub='00000000-0000-0000-0000-000000004141';
SELECT app.api_v1_planner(jsonb_build_object('action','confirm','outfitVersion',1,'operationID',gen_random_uuid(),'id','30000000-0000-0000-0000-000000004141','baseVersion',1));
SELECT pg_sleep(0.2);
COMMIT;
SQL
pids=()
for i in 1 2 3 4; do
 psql -X -At -v ON_ERROR_STOP=1 -d "$database" -f "$artifacts/confirm.sql" > "$artifacts/$i" &
 pids+=("$!")
done
for pid in "${pids[@]}"; do wait "$pid"; done
if grep -q '"error"' "$artifacts/"[1-4]; then cat "$artifacts/"[1-4]; exit 1; fi
psql -X -v ON_ERROR_STOP=1 -d "$database" <<'SQL'
DO $$ BEGIN
 IF (SELECT count(*) FROM app.wear_events WHERE user_id='00000000-0000-0000-0000-000000004141')<>1
 OR (SELECT count(*) FROM api_private.plan_confirmations WHERE user_id='00000000-0000-0000-0000-000000004141')<>1 THEN
 RAISE EXCEPTION 'Concurrent confirmations duplicated history'; END IF;
END $$;
DELETE FROM auth.users WHERE id='00000000-0000-0000-0000-000000004141';
SQL
