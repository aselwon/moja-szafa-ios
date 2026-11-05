BEGIN;
CREATE FUNCTION pg_temp.assert_telemetry(ok boolean,message text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF ok IS DISTINCT FROM true THEN RAISE EXCEPTION 'Telemetry assertion: %',message; END IF; END $$;
INSERT INTO auth.users VALUES('00000000-0000-0000-0000-000000000091'),('00000000-0000-0000-0000-000000000092');
INSERT INTO app.profiles(id,user_id) SELECT id,id FROM auth.users WHERE id IN('00000000-0000-0000-0000-000000000091','00000000-0000-0000-0000-000000000092');
INSERT INTO app.garments(user_id,name,category) SELECT '00000000-0000-0000-0000-000000000091','PRIVATE_GARMENT_NAME','top' FROM generate_series(1,5);
INSERT INTO app.outfits(user_id,name) SELECT '00000000-0000-0000-0000-000000000091','PRIVATE_OUTFIT_NAME' FROM generate_series(1,3);
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000091',true);
DO $$ DECLARE pref jsonb; request jsonb; result jsonb; event jsonb; crash jsonb; BEGIN
 result:=app.api_v1_telemetry('{"action":"get"}');
 PERFORM pg_temp.assert_telemetry(result#>>'{data,diagnostics}'='false' AND result#>>'{data,product}'='false','default opt out');
 event:=jsonb_build_object('id',gen_random_uuid(),'kind','sync','route','sync_cycle','durationMs',123,'outcome','offline');
 request:=jsonb_build_object('action','ingest','version',0,'events',jsonb_build_array(event),'probeActivation',false);
 PERFORM pg_temp.assert_telemetry(app.api_v1_telemetry(request)#>>'{error,code}'='telemetry_disabled','no collection before consent');
 pref:=jsonb_build_object('action','preferences','operationID',gen_random_uuid(),'baseVersion',0,'diagnostics',true,'product',true);
 result:=app.api_v1_telemetry(pref);
 PERFORM pg_temp.assert_telemetry(result#>>'{data,version}'='1','consent saved');
 PERFORM pg_temp.assert_telemetry(app.api_v1_telemetry(pref)=result,'consent exact replay');
 request:=request||'{"version":1,"probeActivation":true}';
 PERFORM pg_temp.assert_telemetry(app.api_v1_telemetry(request)#>>'{data,accepted}'='1','ingestion accepted');
 PERFORM pg_temp.assert_telemetry(app.api_v1_telemetry(request)#>>'{data,accepted}'='1','event retry deduplicated');
 PERFORM pg_temp.assert_telemetry(app.api_v1_telemetry(request||jsonb_build_object('events',jsonb_build_array(event||'{"name":"PRIVATE"}')))#>>'{error,code}'='validation_failed','unknown content field rejected');
 PERFORM pg_temp.assert_telemetry(app.api_v1_telemetry(request||jsonb_build_object('events',jsonb_build_array(event||'{"durationMs":124}')))#>>'{error,code}'='validation_failed','same ID different payload rejected');
 crash:=jsonb_build_object('id',gen_random_uuid(),'kind','crash','build','1','architecture','arm64','frames',jsonb_build_array(jsonb_build_object('binaryUUID',gen_random_uuid(),'offset',12345)));
 PERFORM pg_temp.assert_telemetry(app.api_v1_telemetry(request||jsonb_build_object('events',jsonb_build_array(crash))) ? 'data','bounded symbolication frames accepted');
 PERFORM pg_temp.assert_telemetry(app.api_v1_telemetry(request||jsonb_build_object('events',jsonb_build_array(crash||'{"rawPayload":"PRIVATE"}')))#>>'{error,code}'='validation_failed','raw crash payload never accepted');
 PERFORM set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000092',true);
 PERFORM pg_temp.assert_telemetry(app.api_v1_telemetry('{"action":"get"}')#>>'{data,version}'='0','foreign account consent isolated');
 PERFORM pg_temp.assert_telemetry(app.api_v1_telemetry(request)#>>'{error,code}'='version_conflict','foreign account cannot use opted-in revision');
 PERFORM set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000091',true);
END $$;
RESET ROLE;
SELECT pg_temp.assert_telemetry((SELECT count(*) FROM api_private.telemetry_events WHERE user_id='00000000-0000-0000-0000-000000000091')=4,'one sync, one crash and two real activation milestones');
SELECT pg_temp.assert_telemetry(NOT EXISTS(SELECT FROM api_private.telemetry_events WHERE data::text LIKE '%PRIVATE%'),'no wardrobe content in metrics');
SELECT pg_temp.assert_telemetry(jsonb_array_length(api_private.export_snapshot('00000000-0000-0000-0000-000000000091')->'telemetry_events')=4,'own data export includes telemetry');
SELECT pg_temp.assert_telemetry(jsonb_array_length(api_private.export_snapshot('00000000-0000-0000-0000-000000000092')->'telemetry_events')=0,'export owner isolation');
SELECT pg_temp.assert_telemetry(NOT has_table_privilege('authenticated','api_private.telemetry_events','SELECT'),'no direct diagnostic read');
SELECT pg_temp.assert_telemetry(NOT has_function_privilege('authenticated','app.telemetry_prune()','EXECUTE'),'no public maintenance capability');
SET LOCAL ROLE authenticated;
DO $$ DECLARE result jsonb; request jsonb; BEGIN
 request:=jsonb_build_object('action','preferences','operationID',gen_random_uuid(),'baseVersion',1,'diagnostics',false,'product',false);
 result:=app.api_v1_telemetry(request);
 PERFORM pg_temp.assert_telemetry(result#>>'{data,version}'='2','withdrawal increments consent revision');
 PERFORM pg_temp.assert_telemetry(app.api_v1_telemetry('{"action":"ingest","version":1,"events":[],"probeActivation":true}')#>>'{error,code}'='version_conflict','late batch cannot cross withdrawal');
END $$;
RESET ROLE;
SELECT pg_temp.assert_telemetry(NOT EXISTS(SELECT FROM api_private.telemetry_events WHERE user_id='00000000-0000-0000-0000-000000000091'),'withdrawal removes retained telemetry');
INSERT INTO api_private.telemetry_events(user_id,id,kind,data,received_at) VALUES
 ('00000000-0000-0000-0000-000000000091',gen_random_uuid(),'session','{}',now()-interval '31 days'),
 ('00000000-0000-0000-0000-000000000091',gen_random_uuid(),'session','{}',now()-interval '29 days');
SELECT pg_temp.assert_telemetry(app.telemetry_prune()=1,'bounded retention removes expired rows only');
UPDATE app.profiles SET deleted_at=clock_timestamp() WHERE user_id='00000000-0000-0000-0000-000000000091';
SET LOCAL ROLE authenticated;
SELECT pg_temp.assert_telemetry(app.api_v1_telemetry('{"action":"get"}')#>>'{error,code}'='account_unavailable','deleted account fails closed before replay');
RESET ROLE;
DELETE FROM app.profiles WHERE user_id='00000000-0000-0000-0000-000000000091';
SELECT pg_temp.assert_telemetry(NOT EXISTS(SELECT FROM api_private.telemetry_events) AND NOT EXISTS(SELECT FROM api_private.telemetry_consent_changes),'hard erasure cascades all telemetry');
ROLLBACK;
