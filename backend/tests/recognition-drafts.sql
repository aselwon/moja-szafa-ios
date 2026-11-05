BEGIN;
CREATE FUNCTION pg_temp.assert_true(ok boolean,message text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF ok IS DISTINCT FROM true THEN RAISE EXCEPTION 'Assertion failed: %',message; END IF; END $$;
INSERT INTO auth.users VALUES('00000000-0000-0000-0000-000000000171'),('00000000-0000-0000-0000-000000000172');
INSERT INTO app.profiles(id,user_id) SELECT id,id FROM auth.users WHERE id::text LIKE '%00000000017_';
UPDATE api_private.ai_policy SET enabled=true,image_enabled=true,daily_user_units=20,daily_global_units=20;
INSERT INTO api_private.ai_disclosure VALUES(true,'recognition-test','Cloudflare Workers AI','Synthetic thumbnail','Synthetic recognition test')
 ON CONFLICT(singleton) DO UPDATE SET policy_version=EXCLUDED.policy_version,recipient=EXCLUDED.recipient;
DO $$
DECLARE a uuid:='00000000-0000-0000-0000-000000000171'; b uuid:='00000000-0000-0000-0000-000000000172';
 draft uuid:=gen_random_uuid(); image uuid:=gen_random_uuid(); operation uuid:=gen_random_uuid(); job uuid;
 request jsonb; result_request jsonb; claim jsonb; lease jsonb; value jsonb; disclosure jsonb;
 metadata jsonb:='{"schema_version":"garment-recognition-v1","state":"draft","metadata":{"category":"top","colors":["blue"],"pattern":"plain","seasons":["summer"],"formality":2,"confidence":0.9,"multiple_items":false}}';
BEGIN
 PERFORM set_config('request.jwt.claim.sub',a::text,true);
 value:=app.recognition_images_command(jsonb_build_object('action','prepare','owner',a,'garment',draft,'id',image));
 PERFORM pg_temp.assert_true(value->>'id'=image::text,'prepare a private draft without a garment');
 PERFORM pg_temp.assert_true((SELECT count(*)=0 FROM app.garments WHERE user_id=a),'analysis input is not a wardrobe garment');
 PERFORM pg_temp.assert_true(app.recognition_images_command(jsonb_build_object('action','prepare','owner',b,'garment',draft,'id',image)) IS NULL,'another owner cannot claim draft');
 claim:=app.recognition_images_command(jsonb_build_object('action','claim','owner',a,'id',image));
 PERFORM pg_temp.assert_true(app.recognition_images_command(jsonb_build_object('action','finish','owner',a,'id',image,'fence',gen_random_uuid())) IS NULL,'wrong publication fence');
 PERFORM pg_temp.assert_true(app.recognition_images_command(jsonb_build_object('action','finish','owner',a,'id',image,'fence',claim->>'fence'))='true','publish normalized draft');
 request:=jsonb_build_object('action','enqueue','draft_id',draft,'image_id',image,'operation_id',operation);
 PERFORM pg_temp.assert_true(app.api_v1_recognition(request)#>>'{error,code}'='consent_required','no analysis admission before consent');
 disclosure:=app.api_v1_ai_consent('{}')->'data'->'disclosure';
 PERFORM app.api_v1_ai_consent(jsonb_build_object('operation_id',gen_random_uuid(),'granted',true,'disclosure',disclosure));
 value:=app.api_v1_recognition(request); job:=(value#>>'{data,job_id}')::uuid;
 PERFORM pg_temp.assert_true(job IS NOT NULL,'admission with current disclosure');
 PERFORM pg_temp.assert_true(app.api_v1_recognition(request)#>>'{data,job_id}'=job::text,'uncertain response reuses job');
 PERFORM pg_temp.assert_true((SELECT count(*)=1 FROM app.ai_jobs WHERE user_id=a),'no duplicate job');
 result_request:=jsonb_build_object('action','result','draft_id',draft,'image_id',image,'job_id',job);
 PERFORM pg_temp.assert_true(app.api_v1_recognition(result_request)#>'{data,result}'='null','pending result stays private');
 PERFORM set_config('request.jwt.claim.sub',b::text,true);
 PERFORM pg_temp.assert_true(app.api_v1_recognition(result_request)#>>'{error,code}'='not_found','foreign result denied');
 PERFORM set_config('request.jwt.claim.sub',a::text,true);
 lease:=app.jobs_claim();
 PERFORM pg_temp.assert_true(app.ai_runtime_input(job,(lease->>'lease_token')::uuid)->>'object_key'=image::text||'/thumbnail.jpg','worker reads only bound draft thumbnail');
 PERFORM pg_temp.assert_true(app.jobs_finish(job,(lease->>'lease_token')::uuid,'success',jsonb_build_object('result',metadata)),'synthetic worker finish');
 PERFORM pg_temp.assert_true(app.api_v1_recognition(result_request)#>'{data,result}'=metadata,'validated draft envelope delivered without wardrobe write');
 PERFORM pg_temp.assert_true(app.api_v1_recognition(jsonb_set(result_request,'{image_id}',to_jsonb(gen_random_uuid())))#>>'{error,code}'='not_found','old or mismatched image cannot supply suggestions');
 PERFORM pg_temp.assert_true((SELECT count(*)=0 FROM app.garments WHERE user_id=a),'result still needs explicit garment confirmation');
 request:=jsonb_set(request,'{operation_id}',to_jsonb(gen_random_uuid()));
 job:=(app.api_v1_recognition(request)#>>'{data,job_id}')::uuid; lease:=app.jobs_claim();
 PERFORM pg_temp.assert_true(app.api_v1_recognition(jsonb_build_object('action','discard','draft_id',draft))#>>'{data,discarded}'='true','discard acknowledged');
 PERFORM pg_temp.assert_true(NOT app.jobs_authorize_dispatch(job,(lease->>'lease_token')::uuid),'discard cancels claimed unsent work');
 PERFORM pg_temp.assert_true((SELECT status='released' FROM app.usage_reservations WHERE ai_job_id=job),'discard releases reservation');
 PERFORM pg_temp.assert_true(app.recognition_images_command(jsonb_build_object('action','read','owner',a,'id',image,'variant','thumbnail')) IS NULL,'discarded bytes inaccessible');
 PERFORM pg_temp.assert_true(app.images_command('{"action":"sweep"}') @> jsonb_build_array(jsonb_build_object('id',image)),'shared sweep includes discarded draft');
END $$;
DO $$
DECLARE owner_id uuid:='00000000-0000-0000-0000-000000000171'; draft uuid:=gen_random_uuid();
 old_image uuid:=gen_random_uuid(); replacement uuid:=gen_random_uuid(); claim jsonb;
BEGIN
 PERFORM app.recognition_images_command(jsonb_build_object('action','prepare','owner',owner_id,'garment',draft,'id',old_image));
 claim:=app.recognition_images_command(jsonb_build_object('action','claim','owner',owner_id,'id',old_image));
 UPDATE api_private.image_uploads SET expires_at=clock_timestamp()-interval '1 second' WHERE id=old_image;
 PERFORM pg_temp.assert_true(app.recognition_images_command(jsonb_build_object('action','prepare','owner',owner_id,'garment',draft,'id',old_image))->>'expired'='true','expired namespace asks client to rotate');
 PERFORM pg_temp.assert_true(app.recognition_images_command(jsonb_build_object('action','prepare','owner',owner_id,'garment',draft,'id',replacement))->>'id'=replacement::text,'replacement uses same private draft');
 PERFORM pg_temp.assert_true(app.recognition_images_command(jsonb_build_object('action','finish','owner',owner_id,'id',old_image,'fence',claim->>'fence')) IS NULL,'late retired writer cannot publish');
 UPDATE api_private.recognition_drafts SET expires_at=clock_timestamp()-interval '1 second' WHERE id=draft;
 PERFORM pg_temp.assert_true(app.recognition_images_command(jsonb_build_object('action','claim','owner',owner_id,'id',replacement)) IS NULL,'expired draft cannot claim replacement');
 PERFORM pg_temp.assert_true(app.images_command('{"action":"sweep"}') @> jsonb_build_array(jsonb_build_object('id',replacement)),'expired draft bytes are swept');
END $$;
ROLLBACK;
