#!/usr/bin/env bash
set -euo pipefail
database=${1:?Disposable database required}
artifacts=$(mktemp -d)
trap 'rm -rf "$artifacts"' EXIT
psql -X -At -v ON_ERROR_STOP=1 -d "$database" -c "SELECT pg_get_functiondef('app.images_command(jsonb)'::regprocedure)" > "$artifacts/original.sql"
psql -X -v ON_ERROR_STOP=1 -d "$database" <<'SQL'
INSERT INTO auth.users VALUES('00000000-0000-0000-0000-000000000084');
INSERT INTO app.profiles(id,user_id) VALUES('00000000-0000-0000-0000-000000000084','00000000-0000-0000-0000-000000000084');
INSERT INTO app.purchase_candidates(id,user_id,name,metadata,expires_at,image_id) VALUES('20000000-0000-0000-0000-000000000084','00000000-0000-0000-0000-000000000084','Sweep race','{"category":"top","colors":[],"seasons":[],"formality":null}',clock_timestamp()+interval '5 seconds','40000000-0000-0000-0000-000000000084');
INSERT INTO api_private.image_uploads(id,user_id,purchase_id,state) VALUES('40000000-0000-0000-0000-000000000084','00000000-0000-0000-0000-000000000084','20000000-0000-0000-0000-000000000084','ready');
-- Test-only gate pauses the actual sweep scan after its statement snapshot is
-- acquired, before it can lock the candidate image. No production hook exists.
CREATE FUNCTION api_private.purchase_sweep_gate() RETURNS timestamptz LANGUAGE plpgsql AS $$
BEGIN PERFORM pg_advisory_xact_lock(1804401); RETURN pg_catalog.clock_timestamp(); END $$;
DO $$ BEGIN EXECUTE replace(pg_get_functiondef('app.images_command(jsonb)'::regprocedure),
 'clock_timestamp()', 'api_private.purchase_sweep_gate()'); END $$;
SQL
psql -X -v ON_ERROR_STOP=1 -d "$database" -c 'SELECT pg_advisory_xact_lock(1804401); SELECT pg_sleep(30)' > "$artifacts/holder" 2>&1 &
holder=$!
for attempt in $(seq 1 100); do
 locked=$(psql -X -At -d "$database" -c "SELECT count(*) FROM pg_locks WHERE locktype='advisory' AND objid=1804401 AND granted" 2>/dev/null || true)
 [[ "$locked" == 1 ]] && break
 sleep 0.02
done
[[ "$locked" == 1 ]]
psql -X -At -v ON_ERROR_STOP=1 -d "$database" -c "SELECT app.images_command('{\"action\":\"sweep\"}')" > "$artifacts/sweep" &
sweeper=$!
for attempt in $(seq 1 100); do
 waiting=$(psql -X -At -d "$database" -c "SELECT count(*) FROM pg_locks WHERE locktype='advisory' AND objid=1804401 AND NOT granted")
 [[ "$waiting" == 1 ]] && break
 sleep 0.02
done
[[ "$waiting" == 1 ]]
psql -X -v ON_ERROR_STOP=1 -d "$database" <<'SQL'
BEGIN;
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claim.sub='00000000-0000-0000-0000-000000000084';
DO $$ DECLARE result jsonb; BEGIN
 result:=app.api_v1_purchase('{"action":"confirm","candidate_id":"20000000-0000-0000-0000-000000000084","operation_id":"30000000-0000-0000-0000-000000000084","confirmed":true}');
 IF result->'data'->>'status' IS DISTINCT FROM 'purchased' THEN RAISE EXCEPTION 'Confirmation failed'; END IF;
END $$;
COMMIT;
SELECT pg_sleep(greatest(0,extract(epoch FROM (expires_at-clock_timestamp())))+0.1) FROM app.purchase_candidates WHERE id='20000000-0000-0000-0000-000000000084';
SELECT pg_cancel_backend(pid) FROM pg_locks WHERE locktype='advisory' AND objid=1804401 AND granted;
SQL
wait "$holder" || true
wait "$sweeper"
psql -X -v ON_ERROR_STOP=1 -d "$database" -f "$artifacts/original.sql"
psql -X -v ON_ERROR_STOP=1 -d "$database" <<'SQL'
DO $$ BEGIN
 IF NOT EXISTS(SELECT FROM api_private.image_uploads WHERE id='40000000-0000-0000-0000-000000000084' AND state='ready' AND purchase_id IS NULL AND garment_id IS NOT NULL)
 THEN RAISE EXCEPTION 'Sweep retired a concurrently confirmed image'; END IF;
END $$;
DROP FUNCTION api_private.purchase_sweep_gate();
DELETE FROM auth.users WHERE id='00000000-0000-0000-0000-000000000084';
SQL
