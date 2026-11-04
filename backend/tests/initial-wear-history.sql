BEGIN;
CREATE FUNCTION pg_temp.assert_initial(ok boolean, message text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF ok IS DISTINCT FROM true THEN RAISE EXCEPTION 'Initial history assertion: %',message; END IF; END $$;
INSERT INTO auth.users VALUES ('00000000-0000-0000-0000-000000000071'),('00000000-0000-0000-0000-000000000072');
INSERT INTO app.profiles(id,user_id) SELECT id,id FROM auth.users WHERE id IN ('00000000-0000-0000-0000-000000000071','00000000-0000-0000-0000-000000000072');
INSERT INTO app.garments(id,user_id,name,category,price_grosz) VALUES ('00000000-0000-0000-0000-000000000073','00000000-0000-0000-0000-000000000071','History shirt','top',1200);
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000071',true);
DO $$ DECLARE target uuid:='00000000-0000-0000-0000-000000000073'; request jsonb; result jsonb; before_wears jsonb; day text; BEGIN
 FOREACH day IN ARRAY ARRAY['2026-01-01','2026-01-02','2026-01-03'] LOOP
  PERFORM pg_temp.assert_initial(app.api_v1_save_wear(jsonb_build_object('operationID',gen_random_uuid(),'wear',jsonb_build_object('id',gen_random_uuid(),'version',0,'deleted',false,'wornOn',day,'timezone','Europe/Warsaw','garmentIDs',jsonb_build_array(target)))) ? 'data','fixture wear');
 END LOOP;
 before_wears:=app.api_v1_sync_snapshot('{}')->'data'->'wears';
 request:=jsonb_build_object('operationID',gen_random_uuid(),'id',target,'baseVersion',1,'history',jsonb_build_object('count',10,'startDate','2026-01-02'),'confirmOverlap',false);
 PERFORM pg_temp.assert_initial(app.api_v1_initial_wear_history(request)->'error'->>'code'='validation_failed','overlap requires explicit decision');
 PERFORM pg_temp.assert_initial((SELECT version=1 AND tracking_start_date IS NULL FROM app.garments WHERE id=target),'rejection leaves garment unchanged');
 request:=request||jsonb_build_object('confirmOverlap',true);
 result:=app.api_v1_initial_wear_history(request);
 PERFORM pg_temp.assert_initial(result->'data'->>'version'='2','estimate saved');
 PERFORM pg_temp.assert_initial(result->'data'->'metadata'->'initialWearHistory'=request->'history','estimate projected');
 PERFORM pg_temp.assert_initial(app.api_v1_initial_wear_history(request)=result,'exact replay');
 PERFORM pg_temp.assert_initial(app.api_v1_initial_wear_history(jsonb_set(request,'{history,count}','11'))->'error'->>'code'='idempotency_conflict','changed replay rejected');
 PERFORM pg_temp.assert_initial(app.api_v1_initial_wear_history(request||jsonb_build_object('operationID',gen_random_uuid()))->'error'->>'code'='version_conflict','stale edit rejected');
 PERFORM pg_temp.assert_initial(app.api_v1_sync_snapshot('{}')->'data'->'wears'=before_wears,'estimate does not change diary');
 PERFORM pg_temp.assert_initial(app.api_v1_garment_detail(jsonb_build_object('id',target))->'data'->'garment'->'initialWearHistory'=request->'history','detail projects estimate');
 PERFORM pg_temp.assert_initial(app.api_v1_initial_wear_history(request||jsonb_build_object('operationID',gen_random_uuid(),'baseVersion',2,'history',jsonb_build_object('count',10,'startDate','2025-12-01'),'confirmOverlap',false))->'error'->>'code'='validation_failed','moving boundary earlier also needs overlap decision');
 request:=request||jsonb_build_object('operationID',gen_random_uuid(),'baseVersion',2,'history',NULL);
 PERFORM set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000072',true);
 PERFORM pg_temp.assert_initial(app.api_v1_initial_wear_history(request)->'error'->>'code'='version_conflict','foreign account cannot clear');
 PERFORM set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000071',true);
 result:=app.api_v1_initial_wear_history(request);
 PERFORM pg_temp.assert_initial(result->'data'->'metadata'->'initialWearHistory'='null'::jsonb,'clear returns to exact journal');
 PERFORM pg_temp.assert_initial(app.api_v1_sync_snapshot('{}')->'data'->'wears'=before_wears,'clear preserves diary');
 request:=request||jsonb_build_object('operationID',gen_random_uuid(),'baseVersion',3,'history',jsonb_build_object('count',1,'startDate','2026-02-30'));
 PERFORM pg_temp.assert_initial(app.api_v1_initial_wear_history(request)->'error'->>'code'='validation_failed','invalid calendar date rejected');
 request:=jsonb_build_object('operationID',gen_random_uuid(),'id',target,'baseVersion',3,'history',NULL,'confirmOverlap',false);
 PERFORM pg_temp.assert_initial(app.api_v1_initial_wear_history(request) ? 'data','prepare acknowledged estimate');
 PERFORM pg_temp.assert_initial(app.api_v1_delete_garment(jsonb_build_object('operationID',gen_random_uuid(),'garmentID',target))->>'data'='true','delete garment');
 PERFORM pg_temp.assert_initial(app.api_v1_initial_wear_history(request)->'error'->>'code'='version_conflict','deletion fences cached estimate metadata');

END $$;
ROLLBACK;
