BEGIN;
CREATE FUNCTION pg_temp.assert_history(ok boolean, message text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF ok IS DISTINCT FROM true THEN RAISE EXCEPTION 'History assertion failed: %', message; END IF; END $$;
INSERT INTO auth.users VALUES ('00000000-0000-0000-0000-000000000081'),('00000000-0000-0000-0000-000000000082');
INSERT INTO app.profiles(id,user_id) SELECT id,id FROM auth.users WHERE id IN ('00000000-0000-0000-0000-000000000081','00000000-0000-0000-0000-000000000082');
INSERT INTO app.garments(id,user_id,name,category) VALUES ('00000000-0000-0000-0000-000000000083','00000000-0000-0000-0000-000000000081','History shirt','top');
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000081',true);
DO $$ DECLARE event_id uuid:=gen_random_uuid(); request jsonb; result jsonb; restored jsonb; BEGIN
 PERFORM pg_temp.assert_history(app.api_v1_save_wear(jsonb_build_object('operationID',gen_random_uuid(),'wear',jsonb_build_object(
 'id',event_id,'version',0,'deleted',false,'wornOn','2026-01-01','timezone','Pacific/Kiritimati',
 'garmentIDs',jsonb_build_array('00000000-0000-0000-0000-000000000083')))) ? 'data','create history');
 request:=jsonb_build_object('operationID',gen_random_uuid(),'id',event_id,'baseVersion',1,'action','remove');
 result:=app.api_v1_wear_visibility(request);
 PERFORM pg_temp.assert_history(result->'data'->>'deleted'='true' AND result->'data'->>'version'='2','remove versioned event');
 PERFORM pg_temp.assert_history(app.api_v1_wear_visibility(request)=result,'exact replay after lost response');
 PERFORM pg_temp.assert_history(app.api_v1_wear_visibility(request||jsonb_build_object('action','restore'))->'error'->>'code'='idempotency_conflict','cannot change replay intent');
 request:=request||jsonb_build_object('operationID',gen_random_uuid(),'baseVersion',2,'action','restore');
 PERFORM set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000082',true);
 PERFORM pg_temp.assert_history(app.api_v1_wear_visibility(request)->'error'->>'code'='version_conflict','foreign owner cannot restore');
 PERFORM set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000081',true);
 PERFORM set_config('TimeZone','America/Los_Angeles',true);
 restored:=app.api_v1_wear_visibility(request);
 PERFORM pg_temp.assert_history(restored->'data'->>'deleted'='false' AND restored->'data'->>'version'='3','restore advances version');
 PERFORM pg_temp.assert_history(restored->'data'->>'wornOn'='2026-01-01' AND restored->'data'->>'timezone'='Pacific/Kiritimati','restore preserves historical date and zone');
 PERFORM pg_temp.assert_history(restored->'data'->'garmentIDs'=result->'data'->'garmentIDs','restore preserves membership');
 PERFORM pg_temp.assert_history(app.api_v1_wear_visibility(request)=restored,'restore replay');
 PERFORM pg_temp.assert_history(app.api_v1_wear_visibility(request||jsonb_build_object('operationID',gen_random_uuid()))->'error'->>'code'='version_conflict','stale restore rejected');
 PERFORM pg_temp.assert_history((SELECT count(*)=1 FROM app.wear_events WHERE user_id=auth.uid()),'no duplicate history');
 request:=request||jsonb_build_object('operationID',gen_random_uuid(),'baseVersion',3,'action','remove');
 PERFORM pg_temp.assert_history(app.api_v1_wear_visibility(request) ? 'data','remove again');
 PERFORM app.api_v1_delete_garment(jsonb_build_object('operationID',gen_random_uuid(),'garmentID','00000000-0000-0000-0000-000000000083'));
 request:=request||jsonb_build_object('operationID',gen_random_uuid(),'baseVersion',4,'action','restore');
 PERFORM pg_temp.assert_history(app.api_v1_wear_visibility(request)->'error'->>'code'='validation_failed','deleted garment cannot be revived via history');
END $$;
ROLLBACK;
