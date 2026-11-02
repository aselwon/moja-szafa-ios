BEGIN;
CREATE FUNCTION pg_temp.assert_true(ok boolean, message text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF ok IS DISTINCT FROM true THEN RAISE EXCEPTION 'Assertion failed: %', message; END IF; END $$;
INSERT INTO auth.users VALUES ('00000000-0000-0000-0000-000000000091');
INSERT INTO app.profiles(id,user_id) VALUES ('00000000-0000-0000-0000-000000000091','00000000-0000-0000-0000-000000000091');
INSERT INTO api_private.ai_disclosure VALUES (true,'test-v1','Test recipient','Selected thumbnails and metadata','Classification and outfit suggestions')
ON CONFLICT (singleton) DO UPDATE SET policy_version = excluded.policy_version;
SELECT set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000091',true);
DO $$
DECLARE owner_id uuid := '00000000-0000-0000-0000-000000000091'; d jsonb; choice jsonb; job uuid; queued_job uuid; lease jsonb;
BEGIN
    BEGIN
        PERFORM app.jobs_enqueue(owner_id,gen_random_uuid(),'image_analysis','{}');
        RAISE EXCEPTION 'Expected consent rejection';
    EXCEPTION WHEN invalid_parameter_value THEN NULL; END;
    d := app.api_v1_ai_consent('{}')->'data'->'disclosure';
    choice := jsonb_build_object('operation_id',gen_random_uuid(),'granted',true,'disclosure',d);
    PERFORM pg_temp.assert_true((app.api_v1_ai_consent(choice)->'data'->>'granted')::boolean,'grant');
    PERFORM app.api_v1_ai_consent(choice);
    PERFORM pg_temp.assert_true((SELECT count(*) = 1 FROM app.consent_events WHERE user_id = owner_id),'idempotent evidence');
    job := app.jobs_enqueue(owner_id,gen_random_uuid(),'image_analysis','{}');
    lease := app.jobs_claim();
    queued_job := app.jobs_enqueue(owner_id,gen_random_uuid(),'outfit_generation','{}');
    PERFORM pg_temp.assert_true(app.jobs_authorize_dispatch(job,(lease->>'lease_token')::uuid),'active grant allows dispatch');
    PERFORM app.api_v1_ai_consent(jsonb_build_object('operation_id',gen_random_uuid(),'granted',false,'disclosure',d));
    PERFORM pg_temp.assert_true(NOT app.jobs_authorize_dispatch(job,(lease->>'lease_token')::uuid),'revoked lease denied');
    PERFORM pg_temp.assert_true((SELECT status = 'cancelled' FROM app.ai_jobs WHERE id = queued_job),'cancel unsent queue');
    BEGIN
        PERFORM app.jobs_enqueue(owner_id,gen_random_uuid(),'image_analysis','{}');
        RAISE EXCEPTION 'Expected refusal to block new work';
    EXCEPTION WHEN invalid_parameter_value THEN NULL; END;
    INSERT INTO app.garments(user_id,name,category) VALUES(owner_id,'Manual shirt after refusal','top');
    PERFORM pg_temp.assert_true((SELECT count(*) = 1 FROM app.garments WHERE user_id = owner_id),'manual wardrobe remains writable');
    PERFORM pg_temp.assert_true((SELECT status = 'cancelled' FROM app.ai_jobs WHERE id = job),'cancel claimed job');
    PERFORM pg_temp.assert_true((SELECT status = 'released' FROM app.usage_reservations WHERE ai_job_id = job),'release reservation');
    PERFORM app.api_v1_ai_consent(choice);
    PERFORM pg_temp.assert_true(api_private.ai_consent(owner_id) IS NULL,'old replay cannot regrant');
    choice := jsonb_build_object('operation_id',gen_random_uuid(),'granted',true,'disclosure',d);
    PERFORM app.api_v1_ai_consent(choice);
    job := app.jobs_enqueue(owner_id,gen_random_uuid(),'image_analysis','{}');
    UPDATE api_private.ai_disclosure SET policy_version = 'test-v2';
    lease := app.jobs_claim();
    PERFORM pg_temp.assert_true(NOT app.jobs_authorize_dispatch(job,(lease->>'lease_token')::uuid),'policy change blocks old queue');
    DELETE FROM api_private.ai_disclosure;
    PERFORM pg_temp.assert_true(api_private.ai_consent(owner_id) IS NULL,'missing provider fails closed');
    PERFORM pg_temp.assert_true(app.api_v1_ai_consent(jsonb_build_object('operation_id',gen_random_uuid(),'granted',true,'disclosure',d)) ? 'error','cannot grant missing provider');
    PERFORM set_config('request.jwt.claim.sub','',true);
    PERFORM pg_temp.assert_true(app.api_v1_ai_consent('{}')->'error'->>'code' = 'unauthorized','anonymous denied');
    PERFORM pg_temp.assert_true(NOT has_function_privilege('authenticated','app.jobs_authorize_dispatch(uuid,uuid)','execute'),'client cannot authorize dispatch');
END $$;
ROLLBACK;
