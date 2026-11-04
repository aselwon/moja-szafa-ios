#!/usr/bin/env bash
set -euo pipefail
database=${1:?Disposable test database required}
artifacts=$(mktemp -d)
trap 'rm -rf "$artifacts"' EXIT
psql -X -v ON_ERROR_STOP=1 -d "$database" <<'SQL'
UPDATE api_private.ai_cost_policy SET budget_microunits = committed_microunits + 60;
INSERT INTO auth.users VALUES ('00000000-0000-0000-0000-000000000091'),('00000000-0000-0000-0000-000000000092');
INSERT INTO app.profiles(id,user_id) SELECT id,id FROM auth.users WHERE id::text IN ('00000000-0000-0000-0000-000000000091','00000000-0000-0000-0000-000000000092');
INSERT INTO api_private.ai_disclosure VALUES(true,'test-v1','Test recipient','Metadata','Test purpose') ON CONFLICT DO NOTHING;
INSERT INTO app.consent_events(user_id,purpose,policy_version,recipient,granted,client_request_id,disclosure)
SELECT p.user_id,'ai',d.policy_version,d.recipient,true,gen_random_uuid(),to_jsonb(d)-'singleton'
FROM app.profiles p CROSS JOIN api_private.ai_disclosure d WHERE p.user_id::text IN ('00000000-0000-0000-0000-000000000091','00000000-0000-0000-0000-000000000092');
SQL
for suffix in 91 92; do
    cat > "$artifacts/$suffix.sql" <<SQL
BEGIN;
SET LOCAL ROLE service_role;
SELECT app.jobs_enqueue('00000000-0000-0000-0000-0000000000$suffix',gen_random_uuid(),'image_analysis','{}');
SELECT pg_sleep(0.2);
COMMIT;
SQL
done
psql -X -v ON_ERROR_STOP=1 -d "$database" -f "$artifacts/91.sql" > "$artifacts/a" 2>&1 &
first=$!
psql -X -v ON_ERROR_STOP=1 -d "$database" -f "$artifacts/92.sql" > "$artifacts/b" 2>&1 &
second=$!
a=0; b=0
wait "$first" || a=$?
wait "$second" || b=$?
if ! { { [[ "$a" = 0 ]] && [[ "$b" != 0 ]]; } || { [[ "$a" != 0 ]] && [[ "$b" = 0 ]]; }; }; then
    echo 'Expected exactly one budget admission' >&2; exit 1
fi
if [[ "$a" != 0 ]]; then grep -q ai_budget_exceeded "$artifacts/a"; else grep -q ai_budget_exceeded "$artifacts/b"; fi
psql -X -v ON_ERROR_STOP=1 -d "$database" <<'SQL'
DO $$ BEGIN
    IF (SELECT count(*) FROM app.ai_jobs WHERE user_id::text IN ('00000000-0000-0000-0000-000000000091','00000000-0000-0000-0000-000000000092')) <> 1 THEN
        RAISE EXCEPTION 'Concurrent admission not atomic';
    END IF;
END $$;
DELETE FROM auth.users WHERE id::text IN ('00000000-0000-0000-0000-000000000091','00000000-0000-0000-0000-000000000092');
UPDATE api_private.ai_cost_policy SET budget_microunits = 100000000;
SQL
