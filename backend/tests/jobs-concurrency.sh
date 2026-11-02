#!/usr/bin/env bash
set -euo pipefail
database=${1:?Disposable test database required}
artifacts=$(mktemp -d)
trap 'rm -rf "$artifacts"' EXIT
psql -X -v ON_ERROR_STOP=1 -d "$database" <<'SQL'
INSERT INTO auth.users VALUES ('00000000-0000-0000-0000-000000000080');
INSERT INTO app.profiles(id,user_id) VALUES ('00000000-0000-0000-0000-000000000080','00000000-0000-0000-0000-000000000080');
INSERT INTO api_private.ai_disclosure VALUES (true,'test-v1','Test recipient','Selected thumbnails and metadata','Classification and outfit suggestions') ON CONFLICT DO NOTHING;
INSERT INTO app.consent_events(user_id,purpose,policy_version,recipient,granted,client_request_id,disclosure)
SELECT p.user_id,'ai',d.policy_version,d.recipient,true,gen_random_uuid(),to_jsonb(d) - 'singleton'
FROM app.profiles p CROSS JOIN api_private.ai_disclosure d WHERE p.user_id::text IN ('00000000-0000-0000-0000-000000000080');
SQL
cat > "$artifacts/enqueue.sql" <<'SQL'
BEGIN;
SET LOCAL ROLE service_role;
SELECT app.jobs_enqueue('00000000-0000-0000-0000-000000000080','00000000-0000-0000-0000-000000000080','image_analysis','{}');
SELECT pg_sleep(0.2);
COMMIT;
SQL
psql -X -At -v ON_ERROR_STOP=1 -d "$database" -f "$artifacts/enqueue.sql" > "$artifacts/a" &
first=$!
psql -X -At -v ON_ERROR_STOP=1 -d "$database" -f "$artifacts/enqueue.sql" > "$artifacts/b" &
second=$!
wait "$first"
wait "$second"
diff -u "$artifacts/a" "$artifacts/b"
cat > "$artifacts/claim.sql" <<'SQL'
BEGIN;
SET LOCAL ROLE service_role;
SELECT app.jobs_claim();
SELECT pg_sleep(0.2);
COMMIT;
SQL
psql -X -At -v ON_ERROR_STOP=1 -d "$database" -f "$artifacts/claim.sql" > "$artifacts/a" &
first=$!
psql -X -At -v ON_ERROR_STOP=1 -d "$database" -f "$artifacts/claim.sql" > "$artifacts/b" &
second=$!
wait "$first"
wait "$second"
# Both worker connections have exited. A new process recovers the committed job.
psql -X -v ON_ERROR_STOP=1 -d "$database" <<'SQL'
DO $$ DECLARE j app.ai_jobs%ROWTYPE; recovered jsonb; BEGIN
    SELECT * INTO STRICT j FROM app.ai_jobs WHERE user_id = '00000000-0000-0000-0000-000000000080';
    IF j.attempts <> 1 OR j.status <> 'running' THEN RAISE EXCEPTION 'Concurrent double claim'; END IF;
    UPDATE app.ai_jobs SET lease_expires_at = clock_timestamp() - interval '1 second' WHERE id = j.id;
    PERFORM app.jobs_claim();
    UPDATE app.ai_jobs SET available_at = clock_timestamp() - interval '1 second' WHERE id = j.id;
    recovered := app.jobs_claim();
    IF recovered->>'attempt' <> '2' OR recovered->'input' <> '{}'::jsonb THEN RAISE EXCEPTION 'Lost job on restart'; END IF;
    IF app.jobs_finish(j.id,j.lease_token,'success','{}') THEN RAISE EXCEPTION 'Stale worker won'; END IF;
    IF NOT app.jobs_finish(j.id,(recovered->>'lease_token')::uuid,'success','{"ok":true}') THEN RAISE EXCEPTION 'Recovery failed'; END IF;
END $$;
SQL
# Lost success acknowledgement: another connection repeats enqueue and completion.
psql -X -At -v ON_ERROR_STOP=1 -d "$database" -f "$artifacts/enqueue.sql" > "$artifacts/c"
psql -X -v ON_ERROR_STOP=1 -d "$database" <<'SQL'
DO $$ BEGIN
    IF (SELECT count(*) FROM app.ai_jobs WHERE user_id = '00000000-0000-0000-0000-000000000080') <> 1
       OR (SELECT count(*) FROM app.usage_reservations WHERE user_id = '00000000-0000-0000-0000-000000000080' AND status = 'settled' AND units = 1) <> 1
       OR (SELECT count(*) FROM api_private.job_payloads p JOIN app.ai_jobs j ON j.id = p.job_id
           WHERE j.user_id = '00000000-0000-0000-0000-000000000080' AND p.result = '{"ok":true}'::jsonb) <> 1 THEN
        RAISE EXCEPTION 'Restart lost result or duplicated usage';
    END IF;
END $$;
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000080',false);
DO $$ BEGIN
    IF app.api_v1_list_jobs('{"limit":100,"cursor":null}')->'data'->'items'->0->>'status' <> 'succeeded' THEN
        RAISE EXCEPTION 'Reopened app cannot recover status';
    END IF;
END $$;
RESET ROLE;
DELETE FROM auth.users WHERE id = '00000000-0000-0000-0000-000000000080';
SQL
