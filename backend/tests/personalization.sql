BEGIN;
CREATE FUNCTION pg_temp.assert_personalization(ok boolean,message text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF ok IS DISTINCT FROM true THEN RAISE EXCEPTION 'Personalization assertion: %',message; END IF; END $$;
INSERT INTO auth.users VALUES ('00000000-0000-0000-0000-000000000081'),('00000000-0000-0000-0000-000000000082');
INSERT INTO app.profiles(id,user_id) SELECT id,id FROM auth.users WHERE id IN ('00000000-0000-0000-0000-000000000081','00000000-0000-0000-0000-000000000082');
INSERT INTO app.garments(id,user_id,name,category) VALUES ('00000000-0000-0000-0000-000000000083','00000000-0000-0000-0000-000000000081','Shirt','top');
INSERT INTO app.outfits(id,user_id,name) VALUES ('00000000-0000-0000-0000-000000000084','00000000-0000-0000-0000-000000000081','Work');
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000081',true);
DO $$ DECLARE request jsonb; result jsonb; before_wears jsonb; saved_feedback jsonb; BEGIN
 before_wears:=app.api_v1_sync_snapshot('{}')->'data'->'wears';
 PERFORM pg_temp.assert_personalization(app.api_v1_personalization('{"action":"get"}')->'data'->>'version'='0','initial revision');
 request:=jsonb_build_object('action','preferences','operationID',gen_random_uuid(),'baseVersion',0,'excludedCategories',jsonb_build_array('top'),'colors',jsonb_build_array('blue'));
 result:=app.api_v1_personalization(request);
 PERFORM pg_temp.assert_personalization(result->'data'->>'version'='1','preferences saved');
 PERFORM pg_temp.assert_personalization(result->'data'->'excludedCategories'='["top"]','hard exclusions returned');
 PERFORM pg_temp.assert_personalization(app.api_v1_personalization(request)=result,'exact replay');
 PERFORM pg_temp.assert_personalization(app.api_v1_personalization(request||'{"colors":["red"]}')->'error'->>'code'='idempotency_conflict','different replay rejected');
 PERFORM pg_temp.assert_personalization(app.api_v1_personalization(request||jsonb_build_object('operationID',gen_random_uuid()))->'error'->>'code'='version_conflict','stale update rejected');
 request:=jsonb_build_object('action','feedback','operationID',gen_random_uuid(),'baseVersion',1,'outfitID','00000000-0000-0000-0000-000000000084','rating','dislike','reason','Too formal');
 saved_feedback:=request;
 result:=app.api_v1_personalization(request);
 PERFORM pg_temp.assert_personalization(result->'data'->>'version'='2' AND result->'data'->'feedback'->>'rating'='dislike','feedback saved');
 PERFORM set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000082',true);
 PERFORM pg_temp.assert_personalization(app.api_v1_personalization('{"action":"get"}')->'data'->>'version'='0','foreign account isolated');
 PERFORM pg_temp.assert_personalization(app.api_v1_personalization(request)->'error'->>'code'='validation_failed','foreign outfit inaccessible');
 PERFORM set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000081',true);
 result:=app.api_v1_personalization(jsonb_build_object('action','reset','operationID',gen_random_uuid(),'baseVersion',2));
 PERFORM pg_temp.assert_personalization(result->'data'->>'version'='3' AND result->'data'->'excludedCategories'='[]' AND result->'data'->'colors'='[]','reset clears preferences');
 PERFORM pg_temp.assert_personalization(NOT EXISTS(SELECT FROM app.outfit_feedback),'reset clears feedback');
 PERFORM pg_temp.assert_personalization(app.api_v1_personalization(saved_feedback) ? 'data','old acknowledgement replay allowed');
 PERFORM pg_temp.assert_personalization(NOT EXISTS(SELECT FROM app.outfit_feedback),'replay cannot resurrect feedback');
 PERFORM pg_temp.assert_personalization(app.api_v1_personalization(saved_feedback||jsonb_build_object('operationID',gen_random_uuid()))->'error'->>'code'='version_conflict','reset fences stale device');
 PERFORM pg_temp.assert_personalization(app.api_v1_sync_snapshot('{}')->'data'->'wears'=before_wears,'feedback and reset never alter wear');
 request:=jsonb_build_object('action','preferences','operationID',gen_random_uuid(),'baseVersion',3,'excludedCategories',jsonb_build_array('top'),'colors',jsonb_build_array('blue'));
 PERFORM pg_temp.assert_personalization(app.api_v1_personalization(request) ? 'data','restore exclusion for cached-result test');
END $$;
RESET ROLE;
DO $$ DECLARE result jsonb; BEGIN
 result:=api_private.filter_personalized_result('00000000-0000-0000-0000-000000000081','{"outfits":[{"garment_ids":["00000000-0000-0000-0000-000000000083"],"complete":true}],"other":"preserved"}');
 PERFORM pg_temp.assert_personalization(result->'outfits'='[]' AND result->>'other'='preserved','cached excluded outfit removed as a whole');
 PERFORM pg_temp.assert_personalization(api_private.filter_personalized_result('00000000-0000-0000-0000-000000000082','{"outfits":[],"other":"preserved"}')='{"outfits":[],"other":"preserved"}','unaffected response unchanged');
END $$;
-- The worker hydrates current preferences after admission, before dispatch.
UPDATE api_private.ai_policy SET enabled=true,daily_user_units=100,daily_global_units=100;
INSERT INTO api_private.ai_disclosure VALUES(true,'personalization-test','Cloudflare Workers AI','Synthetic metadata','Synthetic test') ON CONFLICT(singleton) DO UPDATE SET recipient=EXCLUDED.recipient,policy_version=EXCLUDED.policy_version;
INSERT INTO app.consent_events(user_id,purpose,policy_version,recipient,granted,client_request_id,disclosure)
SELECT '00000000-0000-0000-0000-000000000081','ai',d.policy_version,d.recipient,true,gen_random_uuid(),to_jsonb(d)-'singleton' FROM api_private.ai_disclosure d;
INSERT INTO app.outfit_items(user_id,outfit_id,garment_id,position) VALUES('00000000-0000-0000-0000-000000000081','00000000-0000-0000-0000-000000000084','00000000-0000-0000-0000-000000000083',0);
INSERT INTO app.outfit_feedback(user_id,outfit_id,rating,reason) VALUES('00000000-0000-0000-0000-000000000081','00000000-0000-0000-0000-000000000084','like','PRIVATE_REASON');
DO $$ DECLARE owner_id uuid:='00000000-0000-0000-0000-000000000081'; job uuid; lease jsonb; payload jsonb; BEGIN
 job:=app.jobs_enqueue(owner_id,gen_random_uuid(),'outfit_generation','{"count":1}');
 lease:=app.jobs_claim();
 payload:=app.ai_runtime_input(job,(lease->>'lease_token')::uuid);
 PERFORM pg_temp.assert_personalization(payload->'garments'='[]','hard exclusion applied to worker input');
 UPDATE app.preferences SET excluded_categories=ARRAY[]::text[] WHERE user_id=owner_id;
 payload:=app.ai_runtime_input(job,(lease->>'lease_token')::uuid);
 PERFORM pg_temp.assert_personalization(payload->'garments'->0->>'preference_score'='2','feedback influences owner candidate ranking');
 PERFORM pg_temp.assert_personalization(payload#>'{preferences,colors}'='["blue"]','stored colors hydrated');
 PERFORM pg_temp.assert_personalization(position('PRIVATE_REASON' in payload::text)=0,'free text never leaves database');
 DELETE FROM app.outfit_feedback WHERE user_id=owner_id;
 payload:=app.ai_runtime_input(job,(lease->>'lease_token')::uuid);
 PERFORM pg_temp.assert_personalization(payload->'garments'->0->>'preference_score'='0','reset removes ranking influence');
 PERFORM app.jobs_finish(job,(lease->>'lease_token')::uuid,'permanent');
END $$;
ROLLBACK;
