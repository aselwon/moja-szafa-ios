BEGIN;
CREATE FUNCTION pg_temp.assert_true(ok boolean, message text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF ok IS DISTINCT FROM true THEN RAISE EXCEPTION 'Assertion failed: %', message; END IF; END $$;
INSERT INTO auth.users VALUES ('00000000-0000-0000-0000-000000000091'),('00000000-0000-0000-0000-000000000092');
INSERT INTO app.profiles(id,user_id) SELECT id,id FROM auth.users WHERE id IN ('00000000-0000-0000-0000-000000000091','00000000-0000-0000-0000-000000000092');
INSERT INTO app.ai_jobs(id,user_id,client_request_id,kind,status,finished_at) VALUES
 ('10000000-0000-0000-0000-000000000091','00000000-0000-0000-0000-000000000091',gen_random_uuid(),'outfit_generation','succeeded',now());
INSERT INTO api_private.job_payloads(job_id,input,result) VALUES
 ('10000000-0000-0000-0000-000000000091','{"private":"input"}', '{"result":{"outfits":[],"shortfall_reason":"Not enough garments"},"telemetry":{"private":"usage"}}');
INSERT INTO app.garments(id,user_id,name,category) VALUES
 ('20000000-0000-0000-0000-000000000091','00000000-0000-0000-0000-000000000091','Dress','dress');
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claim.sub = '00000000-0000-0000-0000-000000000091';
SELECT pg_temp.assert_true(app.api_v1_latest_suggestions('{}')->'data' = '{"outfits":[],"shortfall_reason":"Not enough garments"}', 'only result, no input or telemetry');
SELECT pg_temp.assert_true(app.api_v1_latest_suggestions('{"owner":"foreign"}')->'error'->>'code' = 'validation_failed', 'no client owner override');
DO $$ DECLARE
 req jsonb := '{"operationID":"30000000-0000-0000-0000-000000000091","id":"40000000-0000-0000-0000-000000000091","baseVersion":0,"name":"Suggestion","favorite":false,"garmentIDs":["20000000-0000-0000-0000-000000000091"]}';
BEGIN
 PERFORM pg_temp.assert_true(app.api_v1_save_suggestion(req)->'data'->>'version' = '1', 'eligible suggestion saved');
END $$;
RESET ROLE;
UPDATE app.garments SET availability = 'laundry' WHERE id = '20000000-0000-0000-0000-000000000091';
SET LOCAL ROLE authenticated;
DO $$ DECLARE
 req jsonb := '{"operationID":"30000000-0000-0000-0000-000000000091","id":"40000000-0000-0000-0000-000000000091","baseVersion":0,"name":"Suggestion","favorite":false,"garmentIDs":["20000000-0000-0000-0000-000000000091"]}';
BEGIN
 PERFORM pg_temp.assert_true(app.api_v1_save_suggestion(req)->'data'->>'version' = '1', 'successful replay survives laundry');
 req := jsonb_set(req, '{operationID}', to_jsonb(gen_random_uuid()));
 PERFORM pg_temp.assert_true(app.api_v1_save_suggestion(req)->'error'->>'code' = 'validation_failed', 'new save rejects laundry');
END $$;
SET LOCAL request.jwt.claim.sub = '00000000-0000-0000-0000-000000000092';
SELECT pg_temp.assert_true(app.api_v1_latest_suggestions('{}')->'data' = 'null', 'foreign result inaccessible');
RESET ROLE;
UPDATE app.profiles SET deleted_at = now() WHERE user_id = '00000000-0000-0000-0000-000000000091';
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claim.sub = '00000000-0000-0000-0000-000000000091';
SELECT pg_temp.assert_true(app.api_v1_latest_suggestions('{}')->'error'->>'code' = 'account_unavailable', 'deleting account blocked');
ROLLBACK;
