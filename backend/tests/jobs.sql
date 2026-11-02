BEGIN;
CREATE FUNCTION pg_temp.assert_true(ok boolean, message text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF ok IS DISTINCT FROM true THEN RAISE EXCEPTION 'Assertion failed: %', message; END IF; END $$;
INSERT INTO auth.users VALUES ('00000000-0000-0000-0000-000000000081'),('00000000-0000-0000-0000-000000000082');
INSERT INTO app.profiles(id,user_id) SELECT id,id FROM auth.users WHERE id IN ('00000000-0000-0000-0000-000000000081','00000000-0000-0000-0000-000000000082');
INSERT INTO api_private.ai_disclosure VALUES (true,'test-v1','Test recipient','Selected thumbnails and metadata','Classification and outfit suggestions') ON CONFLICT DO NOTHING;
INSERT INTO app.consent_events(user_id,purpose,policy_version,recipient,granted,client_request_id,disclosure)
SELECT p.user_id,'ai',d.policy_version,d.recipient,true,gen_random_uuid(),to_jsonb(d) - 'singleton'
FROM app.profiles p CROSS JOIN api_private.ai_disclosure d WHERE p.user_id::text IN ('00000000-0000-0000-0000-000000000081','00000000-0000-0000-0000-000000000082');
-- Inject a failure between result persistence and settlement to prove rollback.
CREATE FUNCTION pg_temp.fail_settlement() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF current_setting('test.fail_settlement',true) = 'yes' AND NEW.status = 'settled' THEN
        RAISE EXCEPTION 'Injected settlement failure' USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER test_settlement BEFORE UPDATE ON app.usage_reservations
    FOR EACH ROW EXECUTE FUNCTION pg_temp.fail_settlement();
DO $$
DECLARE owner_id uuid := '00000000-0000-0000-0000-000000000081';
    operation_id uuid := gen_random_uuid(); target_job uuid; lease jsonb; replacement jsonb; page jsonb;
BEGIN
    target_job := app.jobs_enqueue(owner_id,operation_id,'image_analysis','{"image_id":"private-reference"}',2);
    PERFORM pg_temp.assert_true(app.jobs_enqueue(owner_id,operation_id,'image_analysis','{"image_id":"private-reference"}',2) = target_job,'deduplicate enqueue');
    PERFORM pg_temp.assert_true((SELECT count(*) = 1 FROM app.usage_reservations WHERE ai_job_id = target_job),'one reservation');
    BEGIN
        PERFORM app.jobs_enqueue(owner_id,operation_id,'image_analysis','{"image_id":"different"}',2);
        RAISE EXCEPTION 'Expected idempotency conflict';
    EXCEPTION WHEN invalid_parameter_value THEN NULL; END;
    lease := app.jobs_claim();
    PERFORM pg_temp.assert_true(lease->>'id' = target_job::text AND lease->>'attempt' = '1','first claim');
    PERFORM pg_temp.assert_true(lease->'input' = '{"image_id":"private-reference"}'::jsonb,'durable input');
    PERFORM pg_temp.assert_true(app.jobs_claim() IS NULL,'live lease not stolen');
    PERFORM pg_temp.assert_true(NOT app.jobs_finish(target_job,gen_random_uuid(),'success','{}'),'wrong fence rejected');
    UPDATE app.ai_jobs SET lease_expires_at = clock_timestamp() - interval '1 second' WHERE ai_jobs.id = target_job;
    PERFORM pg_temp.assert_true(NOT app.jobs_finish(target_job,(lease->>'lease_token')::uuid,'success','{}'),'expired fence rejected before reclaim');
    PERFORM pg_temp.assert_true(app.jobs_claim() IS NULL,'expired lease scheduled with backoff');
    UPDATE app.ai_jobs SET available_at = clock_timestamp() - interval '1 second' WHERE ai_jobs.id = target_job;
    replacement := app.jobs_claim();
    PERFORM pg_temp.assert_true(replacement->>'attempt' = '2' AND replacement->>'lease_token' <> lease->>'lease_token','restart new fence');
    PERFORM pg_temp.assert_true(NOT app.jobs_finish(target_job,(lease->>'lease_token')::uuid,'success','{}'),'stale completion rejected');
    PERFORM set_config('test.fail_settlement','yes',true);
    BEGIN
        PERFORM app.jobs_finish(target_job,(replacement->>'lease_token')::uuid,'success','{"category":"top"}');
        RAISE EXCEPTION 'Expected settlement failure';
    EXCEPTION WHEN check_violation THEN NULL; END;
    PERFORM pg_temp.assert_true((SELECT status = 'running' FROM app.ai_jobs WHERE ai_jobs.id = target_job),'settlement failure rolls back terminal state');
    PERFORM pg_temp.assert_true((SELECT result IS NULL FROM api_private.job_payloads WHERE job_id = target_job),'settlement failure rolls back result');
    PERFORM set_config('test.fail_settlement','no',true);
    PERFORM pg_temp.assert_true(app.jobs_finish(target_job,(replacement->>'lease_token')::uuid,'success','{"category":"top"}'),'complete recovered job');
    PERFORM pg_temp.assert_true(NOT app.jobs_finish(target_job,(replacement->>'lease_token')::uuid,'success','{}'),'duplicate completion no-op');
    PERFORM pg_temp.assert_true((SELECT status = 'settled' AND units = 2 FROM app.usage_reservations WHERE ai_job_id = target_job),'single settlement');
    PERFORM pg_temp.assert_true((SELECT result = '{"category":"top"}'::jsonb FROM api_private.job_payloads WHERE job_id = target_job),'result committed');
    PERFORM set_config('request.jwt.claim.sub',owner_id::text,true);
    page := app.api_v1_list_jobs('{"limit":1,"cursor":null}');
    PERFORM pg_temp.assert_true(page->'data'->'items'->0->>'status' = 'succeeded','reopen status');
    PERFORM pg_temp.assert_true(NOT (page->'data'->'items'->0 ?| ARRAY['input','result','lease_token','user_id']),'status excludes private data');
    PERFORM set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000082',true);
    PERFORM pg_temp.assert_true(app.api_v1_list_jobs('{"limit":100,"cursor":null}')->'data'->'items' = '[]'::jsonb,'owner isolation');
    PERFORM set_config('request.jwt.claim.sub','',true);
    PERFORM pg_temp.assert_true(app.api_v1_list_jobs('{"limit":100,"cursor":null}')->'error'->>'code' = 'unauthorized','no identity');
    PERFORM set_config('request.jwt.claim.sub',owner_id::text,true);
    PERFORM pg_temp.assert_true(app.api_v1_list_jobs('{"limit":101,"cursor":null}')->'error'->>'code' = 'validation_failed','page validation');
    -- Timeout/retry budget ends in dead-letter and refunds the original units.
    target_job := app.jobs_enqueue(owner_id,gen_random_uuid(),'image_analysis','{}');
    FOR attempt IN 1..3 LOOP
        UPDATE app.ai_jobs SET available_at = clock_timestamp() - interval '1 second' WHERE ai_jobs.id = target_job;
        lease := app.jobs_claim();
        PERFORM pg_temp.assert_true(lease->>'attempt' = attempt::text,'bounded attempt count');
        PERFORM app.jobs_finish(target_job,(lease->>'lease_token')::uuid,'timeout');
    END LOOP;
    PERFORM pg_temp.assert_true((SELECT status = 'dead_letter' AND attempts = 3 AND finished_at IS NOT NULL FROM app.ai_jobs WHERE ai_jobs.id = target_job),'dead letter');
    PERFORM pg_temp.assert_true((SELECT status = 'released' FROM app.usage_reservations WHERE ai_job_id = target_job),'refund terminal failure');
    PERFORM pg_temp.assert_true(app.jobs_claim() IS NULL,'dead letter never auto replays');
    -- Crash on the final attempt is also recovered to dead-letter.
    target_job := app.jobs_enqueue(owner_id,gen_random_uuid(),'image_analysis','{}');
    UPDATE app.ai_jobs SET max_attempts = 1 WHERE ai_jobs.id = target_job;
    lease := app.jobs_claim();
    UPDATE app.ai_jobs SET lease_expires_at = clock_timestamp() - interval '1 second' WHERE ai_jobs.id = target_job;
    PERFORM app.jobs_claim();
    PERFORM pg_temp.assert_true((SELECT status = 'dead_letter' FROM app.ai_jobs WHERE ai_jobs.id = target_job),'last attempt crash');
    PERFORM pg_temp.assert_true((SELECT status = 'released' FROM app.usage_reservations WHERE ai_job_id = target_job),'last crash refunds');
    target_job := app.jobs_enqueue(owner_id,gen_random_uuid(),'image_analysis','{}');
    lease := app.jobs_claim();
    PERFORM app.jobs_finish(target_job,(lease->>'lease_token')::uuid,'permanent');
    PERFORM pg_temp.assert_true((SELECT status = 'dead_letter' AND attempts = 1 FROM app.ai_jobs WHERE ai_jobs.id = target_job),'permanent failure has no retry');
END $$;
SELECT pg_temp.assert_true(NOT has_function_privilege('authenticated','app.jobs_claim()','EXECUTE'),'client cannot claim');
SELECT pg_temp.assert_true(NOT has_function_privilege('anon','app.api_v1_list_jobs(jsonb)','EXECUTE'),'anonymous cannot list');
SELECT pg_temp.assert_true(NOT has_function_privilege('authenticated','app.jobs_enqueue(uuid,uuid,text,jsonb,integer)','EXECUTE'),'client cannot reserve units');
SELECT pg_temp.assert_true(NOT has_function_privilege('authenticated','app.jobs_finish(uuid,uuid,text,jsonb)','EXECUTE'),'client cannot settle units');
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000081',true);
SELECT pg_temp.assert_true(jsonb_array_length(app.api_v1_list_jobs('{"limit":100,"cursor":null}')->'data'->'items') = 4,'RPC accessible to authenticated role');
RESET ROLE;
ROLLBACK;
