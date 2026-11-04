#!/usr/bin/env bash
set -euo pipefail
database=${1:?Disposable database required}
artifacts=$(mktemp -d)
trap 'rm -rf "$artifacts"' EXIT
psql -X -v ON_ERROR_STOP=1 -d "$database" <<'SQL'
INSERT INTO auth.users VALUES('00000000-0000-0000-0000-000000000083');
INSERT INTO app.profiles(id,user_id) VALUES('00000000-0000-0000-0000-000000000083','00000000-0000-0000-0000-000000000083');
INSERT INTO app.purchase_candidates(id,user_id,name,metadata,expires_at,image_id) VALUES('20000000-0000-0000-0000-000000000083','00000000-0000-0000-0000-000000000083','Concurrent purchase','{"category":"top","colors":[],"seasons":[],"formality":null}',clock_timestamp()+interval '1 day','40000000-0000-0000-0000-000000000083');
INSERT INTO api_private.image_uploads(id,user_id,purchase_id,state) VALUES('40000000-0000-0000-0000-000000000083','00000000-0000-0000-0000-000000000083','20000000-0000-0000-0000-000000000083','ready');
SQL
cat > "$artifacts/request.sql" <<'SQL'
BEGIN;
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claim.sub='00000000-0000-0000-0000-000000000083';
SELECT app.api_v1_purchase(jsonb_build_object('action','confirm','candidate_id','20000000-0000-0000-0000-000000000083','operation_id',gen_random_uuid(),'confirmed',true))->'data'->>'garment_id';
SELECT pg_sleep(0.2);
COMMIT;
SQL
pids=()
for i in 1 2 3 4; do
 psql -X -At -v ON_ERROR_STOP=1 -d "$database" -f "$artifacts/request.sql" > "$artifacts/$i" &
 pids+=("$!")
done
for pid in "${pids[@]}"; do wait "$pid"; done
for i in 2 3 4; do diff -u "$artifacts/1" "$artifacts/$i"; done
psql -X -v ON_ERROR_STOP=1 -d "$database" <<'SQL'
DO $$ BEGIN
 IF (SELECT count(*) FROM app.garments WHERE user_id='00000000-0000-0000-0000-000000000083')<>1
 OR (SELECT count(*) FROM app.garment_images WHERE user_id='00000000-0000-0000-0000-000000000083')<>2
 THEN RAISE EXCEPTION 'Concurrent confirmation duplicated purchase'; END IF;
END $$;
DELETE FROM auth.users WHERE id='00000000-0000-0000-0000-000000000083';
SQL
