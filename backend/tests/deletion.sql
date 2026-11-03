BEGIN;
INSERT INTO auth.users VALUES ('17000000-0000-4000-8000-000000000001'), ('17000000-0000-4000-8000-000000000002');
INSERT INTO app.profiles(id,user_id) SELECT id,id FROM auth.users WHERE id::text LIKE '17000000%';
INSERT INTO app.garments(user_id,name,category) VALUES ('17000000-0000-4000-8000-000000000001','private','top');
DO $$ DECLARE first jsonb; second jsonb; job jsonb; BEGIN
    first := app.deletion_command('{"action":"request","owner":"17000000-0000-4000-8000-000000000001","id":"17000000-0000-4000-8000-000000000003"}');
    second := app.deletion_command('{"action":"request","owner":"17000000-0000-4000-8000-000000000001","id":"17000000-0000-4000-8000-000000000004"}');
    IF first IS DISTINCT FROM second OR first->>'status' <> 'accepted' THEN RAISE EXCEPTION 'retry not idempotent'; END IF;
    IF EXISTS (SELECT FROM app.profiles WHERE user_id = '17000000-0000-4000-8000-000000000001' AND deleted_at IS NULL) THEN RAISE EXCEPTION 'account not fenced'; END IF;
END $$;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub','17000000-0000-4000-8000-000000000001',true);
DO $$ BEGIN
    IF EXISTS (SELECT FROM app.garments) OR EXISTS (SELECT FROM app.profiles) THEN
        RAISE EXCEPTION 'stale session can read deleted account';
    END IF;
    IF has_function_privilege('authenticated','app.deletion_command(jsonb)','EXECUTE') THEN
        RAISE EXCEPTION 'client can bypass reauthentication';
    END IF;
    IF app.api_v1_sync_snapshot('{}')->'error'->>'code' IS DISTINCT FROM 'account_unavailable' THEN
        RAISE EXCEPTION 'offline synchronization not blocked';
    END IF;
END $$;
RESET ROLE;
DO $$ DECLARE job jsonb; BEGIN
    job := app.deletion_command('{"action":"claim"}');
    IF app.deletion_command(jsonb_build_object('action','finish','id',job->>'id','fence',gen_random_uuid())) <> 'false'::jsonb THEN RAISE EXCEPTION 'stale worker accepted'; END IF;
    IF app.deletion_command(job || '{"action":"finish"}') <> 'true'::jsonb THEN RAISE EXCEPTION 'cleanup failed'; END IF;
    IF EXISTS (SELECT FROM app.garments WHERE user_id = '17000000-0000-4000-8000-000000000001') THEN RAISE EXCEPTION 'data survived'; END IF;
    IF NOT EXISTS (SELECT FROM app.profiles WHERE user_id = '17000000-0000-4000-8000-000000000002') THEN RAISE EXCEPTION 'other account removed'; END IF;
    IF NOT EXISTS (SELECT FROM app.deletion_jobs WHERE user_id = '17000000-0000-4000-8000-000000000001' AND status = 'succeeded') THEN RAISE EXCEPTION 'ledger lost'; END IF;
END $$;
ROLLBACK;
