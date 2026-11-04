BEGIN;
CREATE FUNCTION pg_temp.assert_true(ok boolean,message text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF ok IS DISTINCT FROM true THEN RAISE EXCEPTION 'Assertion failed: %',message; END IF; END $$;
INSERT INTO auth.users VALUES ('00000000-0000-0000-0000-000000000081'),('00000000-0000-0000-0000-000000000082');
INSERT INTO app.profiles(id,user_id) SELECT id,id FROM auth.users WHERE id IN('00000000-0000-0000-0000-000000000081','00000000-0000-0000-0000-000000000082');
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claim.sub='00000000-0000-0000-0000-000000000081';
DO $$ DECLARE r jsonb; q jsonb:='{"action":"create","operation_id":"10000000-0000-0000-0000-000000000081","candidate_id":"20000000-0000-0000-0000-000000000081","name":"Potential jacket","price_grosz":12900,"metadata":{"category":"outerwear","colors":["blue"],"seasons":["autumn"],"formality":2}}';
BEGIN
 r:=app.api_v1_purchase(q); PERFORM pg_temp.assert_true(r->'data'->>'status'='considering','candidate created');
 PERFORM pg_temp.assert_true(app.api_v1_purchase(q)=r,'create replay identical');
 PERFORM pg_temp.assert_true(NOT EXISTS(SELECT FROM app.garments WHERE user_id=auth.uid()),'candidate is not owned garment');
 PERFORM pg_temp.assert_true(app.api_v1_purchase('{"action":"confirm","candidate_id":"20000000-0000-0000-0000-000000000081","operation_id":"30000000-0000-0000-0000-000000000081","confirmed":false}')->'error'->>'code'='validation_failed','explicit confirmation required');
 PERFORM pg_temp.assert_true(app.api_v1_purchase('{"action":"confirm","candidate_id":"20000000-0000-0000-0000-000000000081","operation_id":"30000000-0000-0000-0000-000000000081","confirmed":true}')->'error'->>'code'='validation_failed','unready photo cannot convert');
END $$;
RESET ROLE;
SELECT pg_temp.assert_true(app.purchase_images_command('{"action":"prepare","owner":"00000000-0000-0000-0000-000000000082","garment":"20000000-0000-0000-0000-000000000081","id":"40000000-0000-0000-0000-000000000081"}') IS NULL,'foreign owner cannot prepare image');
DO $$ DECLARE r jsonb; q jsonb:='{"owner":"00000000-0000-0000-0000-000000000081","garment":"20000000-0000-0000-0000-000000000081","id":"40000000-0000-0000-0000-000000000081"}';
BEGIN
 PERFORM pg_temp.assert_true(app.purchase_images_command(q||'{"action":"prepare"}')->>'id'='40000000-0000-0000-0000-000000000081','private purchase photo prepared');
 r:=app.purchase_images_command(q||'{"action":"claim"}');
 PERFORM pg_temp.assert_true(app.purchase_images_command(q||jsonb_build_object('action','finish','fence',r->>'fence'))='true'::jsonb,'normalized upload fenced publication');
 PERFORM pg_temp.assert_true(app.images_command(q||'{"action":"read"}')='null'::jsonb,'ordinary garment route cannot read temporary photo');
 PERFORM pg_temp.assert_true(app.purchase_images_command(q||'{"action":"read","owner":"00000000-0000-0000-0000-000000000082"}') IS NULL,'foreign photo read denied');
END $$;
INSERT INTO api_private.ai_disclosure VALUES(true,'purchase-test','Cloudflare Workers AI','Manually entered metadata','Purchase fit test') ON CONFLICT(singleton) DO UPDATE SET recipient=EXCLUDED.recipient,policy_version=EXCLUDED.policy_version;
INSERT INTO app.consent_events(user_id,purpose,policy_version,recipient,granted,client_request_id,disclosure)
SELECT '00000000-0000-0000-0000-000000000081'::uuid,'ai',d.policy_version,d.recipient,true,gen_random_uuid(),to_jsonb(d)-'singleton' FROM api_private.ai_disclosure d;
DO $$ DECLARE job uuid; lease jsonb; payload jsonb;
BEGIN
 UPDATE api_private.ai_policy SET enabled=true,image_enabled=false,daily_user_units=10,daily_global_units=10;
 job:=app.jobs_enqueue('00000000-0000-0000-0000-000000000081',gen_random_uuid(),'purchase_fit','{"candidate_id":"20000000-0000-0000-0000-000000000081"}',1);
 PERFORM pg_temp.assert_true((SELECT units=2 FROM app.usage_reservations WHERE ai_job_id=job),'purchase fit reserves first call and one repair');
 lease:=app.jobs_claim();
 payload:=app.ai_runtime_input(job,(lease->>'lease_token')::uuid);
 PERFORM pg_temp.assert_true(payload->'purchase_candidate'->>'id'='20000000-0000-0000-0000-000000000081','owner candidate metadata resolved');
 PERFORM pg_temp.assert_true(NOT payload ?| ARRAY['object_key','image_id','base64'],'no photo sent by metadata-only fit');
 PERFORM pg_temp.assert_true(app.ai_runtime_dispatch(job,(lease->>'lease_token')::uuid,'Cloudflare Workers AI'),'text fit works while vision disabled');
 PERFORM pg_temp.assert_true(NOT app.ai_runtime_dispatch(job,(lease->>'lease_token')::uuid,'Cloudflare Workers AI'),'no unexplained repeat dispatch');
 PERFORM app.ai_runtime_telemetry(job,1,1,'{"status":"outfit_json_invalid"}');
 PERFORM pg_temp.assert_true(app.ai_runtime_dispatch(job,(lease->>'lease_token')::uuid,'Cloudflare Workers AI'),'one evidenced JSON repair');
 PERFORM pg_temp.assert_true(NOT app.ai_runtime_dispatch(job,(lease->>'lease_token')::uuid,'Cloudflare Workers AI'),'third purchase call blocked');
 PERFORM app.jobs_finish(job,(lease->>'lease_token')::uuid,'permanent');
 PERFORM pg_temp.assert_true(api_private.export_snapshot('00000000-0000-0000-0000-000000000081')->'purchase_images' @> '[{"id":"40000000-0000-0000-0000-000000000081"}]','temporary image included in owner export');
END $$;
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claim.sub='00000000-0000-0000-0000-000000000082';
SELECT pg_temp.assert_true(app.api_v1_purchase('{"action":"confirm","candidate_id":"20000000-0000-0000-0000-000000000081","operation_id":"30000000-0000-0000-0000-000000000082","confirmed":true}')->'error'->>'code'='not_found','foreign confirm does not disclose candidate');
SET LOCAL request.jwt.claim.sub='00000000-0000-0000-0000-000000000081';
DO $$ DECLARE first jsonb; retry jsonb; q jsonb:='{"action":"confirm","candidate_id":"20000000-0000-0000-0000-000000000081","operation_id":"30000000-0000-0000-0000-000000000081","confirmed":true}';
BEGIN
 first:=app.api_v1_purchase(q); PERFORM pg_temp.assert_true(first->'data'->>'status'='purchased','explicit confirm converts');
 PERFORM pg_temp.assert_true(app.api_v1_purchase(q)=first,'same operation replay');
 retry:=app.api_v1_purchase(q||jsonb_build_object('operation_id',gen_random_uuid()));
 PERFORM pg_temp.assert_true(retry->'data'->>'garment_id'=first->'data'->>'garment_id','different device confirmation returns same garment');
 PERFORM pg_temp.assert_true((SELECT count(*)=1 FROM app.garments WHERE user_id=auth.uid()),'exactly one owned garment');
 PERFORM pg_temp.assert_true((SELECT count(*)=2 FROM app.garment_images WHERE user_id=auth.uid()),'image variants atomically transferred');
 PERFORM pg_temp.assert_true(NOT EXISTS(SELECT FROM app.wear_events WHERE user_id=auth.uid()),'purchase creates no projected wears/CPW');
END $$;
RESET ROLE;
SELECT pg_temp.assert_true(app.purchase_images_command('{"action":"read","owner":"00000000-0000-0000-0000-000000000081","id":"40000000-0000-0000-0000-000000000081"}') IS NULL,'temporary read revoked after conversion');
SELECT pg_temp.assert_true(app.images_command('{"action":"read","owner":"00000000-0000-0000-0000-000000000081","id":"40000000-0000-0000-0000-000000000081"}')='true'::jsonb,'owned read available after conversion');
INSERT INTO app.purchase_candidates(id,user_id,name,expires_at) VALUES('20000000-0000-0000-0000-000000000082','00000000-0000-0000-0000-000000000081','Expired',clock_timestamp()-interval '1 hour');
INSERT INTO api_private.image_uploads(id,user_id,purchase_id,state) VALUES('40000000-0000-0000-0000-000000000082','00000000-0000-0000-0000-000000000081','20000000-0000-0000-0000-000000000082','ready');
SELECT pg_temp.assert_true(app.images_command('{"action":"sweep"}') @> '[{"id":"40000000-0000-0000-0000-000000000082"}]','expired temporary photo swept');
SELECT pg_temp.assert_true((SELECT state='ready' FROM api_private.image_uploads WHERE id='40000000-0000-0000-0000-000000000081'),'converted photo survives candidate cleanup');
ROLLBACK;
