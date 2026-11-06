#!/usr/bin/env bash
set -euo pipefail
[[ ${AI_DEPLOYMENT_PG_TESTS:-} == 1 ]] || { echo 'Disposable PostgreSQL test cluster required' >&2; exit 1; }
root=$(cd "$(dirname "$0")/.." && pwd)
database="szafa_ai_deploy_${$}_${RANDOM}"
login="${database}_login"
cleanup() {
  dropdb --if-exists "$database"
  psql -Xq -v ON_ERROR_STOP=1 -d postgres -c "DROP ROLE IF EXISTS $login"
}
trap cleanup EXIT
createdb "$database"
psql -Xq -v ON_ERROR_STOP=1 -d "$database" -f "$root/tests/bootstrap.sql"
bash "$root/migrate.sh" "$database"
for attempt in 1 2; do
  psql -Xq -v ON_ERROR_STOP=1 --single-transaction -d "$database" -f "$root/deploy/neon-ai-worker.sql"
done
psql -Xq -v ON_ERROR_STOP=1 -d "$database" -c "CREATE ROLE $login LOGIN NOINHERIT NOBYPASSRLS; GRANT szafa_ai_worker TO $login"
PGOPTIONS='-c role=szafa_ai_worker' psql -Xq -v ON_ERROR_STOP=1 -U "$login" -d "$database" -f "$root/tests/ai-worker-deployment.sql"
psql -Xq -v ON_ERROR_STOP=1 -d "$database" <<'SQL'
BEGIN;
INSERT INTO auth.users VALUES('00000000-0000-0000-0000-000000000099');
INSERT INTO app.profiles(id,user_id) VALUES('00000000-0000-0000-0000-000000000099','00000000-0000-0000-0000-000000000099');
INSERT INTO app.ai_jobs(user_id,client_request_id,kind) VALUES('00000000-0000-0000-0000-000000000099',gen_random_uuid(),'trip');
UPDATE api_private.ai_policy SET enabled=true,image_enabled=false;
SET LOCAL ROLE szafa_ai_worker;
DO $$ BEGIN
 IF app.ai_worker_claim() IS NOT NULL THEN RAISE EXCEPTION 'Unsupported job consumed'; END IF;
END $$;
RESET ROLE;
DO $$ BEGIN
 IF EXISTS(SELECT FROM app.ai_jobs WHERE attempts<>0 OR status<>'queued') THEN RAISE EXCEPTION 'Unsupported job changed'; END IF;
END $$;
ROLLBACK;
SQL
psql -Xq -v ON_ERROR_STOP=1 -d "$database" -f "$root/tests/ai-image-worker-deployment.sql"
echo 'PASS: narrow AI worker role, explicit libpq role, disabled defaults and replayable deployment'
