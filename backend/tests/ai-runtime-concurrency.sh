#!/usr/bin/env bash
set -euo pipefail
database=${1:?database required}
artifacts=$(mktemp -d)
trap 'rm -rf "$artifacts"' EXIT
psql -X -v ON_ERROR_STOP=1 -d "$database" <<'SQL'
INSERT INTO auth.users VALUES('00000000-0000-0000-0000-000000000093');
INSERT INTO app.profiles(id,user_id) VALUES('00000000-0000-0000-0000-000000000093','00000000-0000-0000-0000-000000000093');
INSERT INTO app.consent_events(user_id,purpose,policy_version,recipient,granted,client_request_id,disclosure)
SELECT '00000000-0000-0000-0000-000000000093','ai',policy_version,recipient,true,gen_random_uuid(),to_jsonb(d)-'singleton' FROM api_private.ai_disclosure d;
UPDATE api_private.ai_policy SET enabled=true,daily_global_units=1,daily_user_units=1;
SQL
for index in 1 2 3 4 5 6 7 8; do
    psql -X -At -v ON_ERROR_STOP=1 -d "$database" -c "SELECT app.jobs_enqueue('00000000-0000-0000-0000-000000000093',gen_random_uuid(),'image_analysis','{}')" > "$artifacts/$index" 2>&1 &
done
wait || true
for index in 1 2 3 4 5 6 7 8; do
    if ! grep -Eq '^[0-9a-f-]{36}$|AI quota exhausted' "$artifacts/$index"; then
        echo 'Unexpected concurrent admission failure' >&2; exit 1
    fi
done
psql -X -v ON_ERROR_STOP=1 -d "$database" <<'SQL'
DO $$ BEGIN
 IF (SELECT count(*) FROM app.ai_jobs WHERE user_id='00000000-0000-0000-0000-000000000093')<>1 THEN
   RAISE EXCEPTION 'Concurrent admission exceeded or failed available quota'; END IF;
END $$;
DELETE FROM auth.users WHERE id='00000000-0000-0000-0000-000000000093';
UPDATE api_private.ai_policy SET enabled=true,daily_global_units=1000000,daily_user_units=1000000;
SQL
