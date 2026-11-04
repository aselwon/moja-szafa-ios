BEGIN;
CREATE FUNCTION pg_temp.assert_true(ok boolean, message text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF ok IS DISTINCT FROM true THEN RAISE EXCEPTION 'Assertion failed: %', message; END IF; END $$;
INSERT INTO auth.users VALUES ('00000000-0000-0000-0000-000000000081'),('00000000-0000-0000-0000-000000000082');
INSERT INTO app.profiles(id,user_id) SELECT id,id FROM auth.users WHERE id IN ('00000000-0000-0000-0000-000000000081','00000000-0000-0000-0000-000000000082');
INSERT INTO api_private.ai_disclosure VALUES (true,'test-v1','Test recipient','Selected thumbnails and metadata','Classification and outfit suggestions') ON CONFLICT DO NOTHING;
INSERT INTO app.consent_events(user_id,purpose,policy_version,recipient,granted,client_request_id,disclosure)
SELECT p.user_id,'ai',d.policy_version,d.recipient,true,gen_random_uuid(),to_jsonb(d) - 'singleton'
FROM app.profiles p CROSS JOIN api_private.ai_disclosure d WHERE p.user_id::text IN ('00000000-0000-0000-0000-000000000081','00000000-0000-0000-0000-000000000082');
DO $$
DECLARE owner_id uuid := '00000000-0000-0000-0000-000000000081';
    other_id uuid := '00000000-0000-0000-0000-000000000082';
    j uuid; op uuid := gen_random_uuid(); lease jsonb;
BEGIN
    UPDATE api_private.ai_cost_policy SET monthly_user_units = 1, budget_microunits = 60, committed_microunits = 0;
    j := app.jobs_enqueue(owner_id,op,'image_analysis','{}');
    PERFORM pg_temp.assert_true(app.jobs_enqueue(owner_id,op,'image_analysis','{}') = j,'replay does not reserve twice');
    PERFORM pg_temp.assert_true((SELECT committed_microunits = 60 FROM api_private.ai_cost_policy),'all retries and repair reserved');
    BEGIN
        PERFORM app.jobs_enqueue(owner_id,gen_random_uuid(),'image_analysis','{}');
        RAISE EXCEPTION 'quota admitted excess';
    EXCEPTION WHEN invalid_parameter_value THEN
        PERFORM pg_temp.assert_true(SQLERRM = 'ai_quota_exceeded','quota error');
    END;
    BEGIN
        PERFORM app.jobs_enqueue(other_id,gen_random_uuid(),'image_analysis','{}');
        RAISE EXCEPTION 'budget admitted excess';
    EXCEPTION WHEN invalid_parameter_value THEN
        PERFORM pg_temp.assert_true(SQLERRM = 'ai_budget_exceeded','global budget across users');
    END;
    lease := app.jobs_claim();
    PERFORM app.jobs_finish(j,(lease->>'lease_token')::uuid,'permanent');
    PERFORM pg_temp.assert_true((SELECT committed_microunits = 0 FROM api_private.ai_cost_policy),'undispatched failure refunds budget');
    j := app.jobs_enqueue(owner_id,gen_random_uuid(),'image_analysis','{}');
    lease := app.jobs_claim();
    PERFORM pg_temp.assert_true(app.jobs_authorize_dispatch(j,(lease->>'lease_token')::uuid),'dispatch with budget');
    PERFORM pg_temp.assert_true(app.jobs_authorize_dispatch(j,(lease->>'lease_token')::uuid),'repeated authorization is idempotent');
    PERFORM app.jobs_finish(j,(lease->>'lease_token')::uuid,'permanent');
    PERFORM pg_temp.assert_true((SELECT status = 'released' FROM app.usage_reservations WHERE ai_job_id = j),'failed job releases user units');
    PERFORM pg_temp.assert_true((SELECT committed_microunits = 60 FROM api_private.ai_cost_policy),'unknown billing remains in global budget');
    UPDATE api_private.ai_cost_policy SET budget_microunits = 120;
    j := app.jobs_enqueue(owner_id,gen_random_uuid(),'image_analysis','{}');
    lease := app.jobs_claim();
    UPDATE api_private.ai_cost_policy SET enabled = false;
    PERFORM pg_temp.assert_true(NOT app.jobs_authorize_dispatch(j,(lease->>'lease_token')::uuid),'kill switch blocks queued dispatch');
    PERFORM pg_temp.assert_true((SELECT status = 'released' FROM app.usage_reservations WHERE ai_job_id = j),'kill switch releases reservation');
    BEGIN
        PERFORM app.jobs_enqueue(other_id,gen_random_uuid(),'image_analysis','{}');
        RAISE EXCEPTION 'disabled admission succeeded';
    EXCEPTION WHEN invalid_parameter_value THEN
        PERFORM pg_temp.assert_true(SQLERRM = 'ai_disabled','kill switch blocks admission');
    END;
    UPDATE api_private.ai_cost_policy SET enabled = true;
    j := app.jobs_enqueue(owner_id,gen_random_uuid(),'image_analysis','{}');
    BEGIN
        UPDATE app.ai_jobs SET max_attempts = 4 WHERE id = j;
        RAISE EXCEPTION 'retry envelope increased';
    EXCEPTION WHEN invalid_parameter_value THEN NULL; END;
    lease := app.jobs_claim();
    PERFORM app.jobs_authorize_dispatch(j,(lease->>'lease_token')::uuid);
    PERFORM app.jobs_finish(j,(lease->>'lease_token')::uuid,'success','{}');
    PERFORM pg_temp.assert_true((SELECT status = 'settled' FROM app.usage_reservations WHERE ai_job_id = j),'success settles quota');
    DELETE FROM auth.users WHERE id = owner_id;
    PERFORM pg_temp.assert_true((SELECT committed_microunits = 120 FROM api_private.ai_cost_policy),'account deletion cannot erase possible provider charges');
    DELETE FROM api_private.ai_cost_policy;
    BEGIN
        PERFORM app.jobs_enqueue(other_id,gen_random_uuid(),'image_analysis','{}');
        RAISE EXCEPTION 'missing policy admitted';
    EXCEPTION WHEN invalid_parameter_value THEN NULL; END;
END $$;
SELECT pg_temp.assert_true(NOT has_table_privilege('authenticated','api_private.ai_cost_policy','UPDATE'),'client cannot enable AI');
SELECT pg_temp.assert_true(NOT has_table_privilege('service_role','api_private.ai_cost_policy','UPDATE'),'worker cannot raise its budget');
SELECT pg_temp.assert_true(NOT has_function_privilege('service_role','app.jobs_authorize_dispatch_consent(uuid,uuid)','EXECUTE'),'worker cannot bypass cost authorization');
ROLLBACK;
