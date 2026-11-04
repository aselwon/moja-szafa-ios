BEGIN;
CREATE FUNCTION pg_temp.assert_true(ok boolean,message text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF ok IS DISTINCT FROM true THEN RAISE EXCEPTION 'Assertion failed: %',message; END IF; END $$;
INSERT INTO auth.users VALUES ('00000000-0000-0000-0000-000000000043'),('00000000-0000-0000-0000-000000000044');
INSERT INTO app.profiles(id,user_id) SELECT id,id FROM auth.users WHERE id IN ('00000000-0000-0000-0000-000000000043','00000000-0000-0000-0000-000000000044');
INSERT INTO app.garments(id,user_id,name,category,price_grosz) VALUES
 ('10000000-0000-0000-0000-000000000043','00000000-0000-0000-0000-000000000043','Dress','dress',10000),
 ('10000000-0000-0000-0000-000000000044','00000000-0000-0000-0000-000000000043','Shoes','shoes',20000),
 ('10000000-0000-0000-0000-000000000045','00000000-0000-0000-0000-000000000044','Foreign','top',30000);
INSERT INTO app.outfits(id,user_id,name) VALUES
 ('20000000-0000-0000-0000-000000000043','00000000-0000-0000-0000-000000000043','Travel'),
 ('20000000-0000-0000-0000-000000000044','00000000-0000-0000-0000-000000000044','Foreign');
INSERT INTO app.outfit_items(user_id,outfit_id,garment_id,position) VALUES
 ('00000000-0000-0000-0000-000000000043','20000000-0000-0000-0000-000000000043','10000000-0000-0000-0000-000000000043',0),
 ('00000000-0000-0000-0000-000000000043','20000000-0000-0000-0000-000000000043','10000000-0000-0000-0000-000000000044',1),
 ('00000000-0000-0000-0000-000000000044','20000000-0000-0000-0000-000000000044','10000000-0000-0000-0000-000000000045',0);
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claim.sub='00000000-0000-0000-0000-000000000043';
DO $$ DECLARE
 req jsonb:='{"action":"save","operationID":"40000000-0000-0000-0000-000000000043","id":"30000000-0000-0000-0000-000000000043","baseVersion":0,"trip":{"destination":"Warsaw","startsOn":"2026-11-05","endsOn":"2026-11-06","timezone":"Europe/Warsaw","occasions":["Work","Dinner"],"maxItems":2,"days":[{"day":"2026-11-05","outfitID":"20000000-0000-0000-0000-000000000043","outfitVersion":1},{"day":"2026-11-06","outfitID":"20000000-0000-0000-0000-000000000043","outfitVersion":1}]}}';
 result jsonb; bad jsonb; packed jsonb;
BEGIN
 result:=app.api_v1_trips(req);
 PERFORM pg_temp.assert_true(result->'data'->>'destination'='Warsaw','destination persisted');
 PERFORM pg_temp.assert_true(result->'data'->'occasions'='["Work","Dinner"]','occasions persisted');
 PERFORM pg_temp.assert_true(jsonb_array_length(result->'data'->'packing')=2,'unique packing union, not repeated count');
 PERFORM pg_temp.assert_true(jsonb_array_length(result->'data'->'days')=2,'every day planned');
 PERFORM pg_temp.assert_true(result->'data'->'days'->0->>'repeated'='true','intentional repeated garments visible');
 PERFORM pg_temp.assert_true(result->'data'->'days'->0->'missingCategories'='[]','complete outfit categories');
 PERFORM pg_temp.assert_true(app.api_v1_trips(req)=result,'save replay');
 PERFORM pg_temp.assert_true(app.api_v1_trips(jsonb_set(req,'{trip,destination}','"Paris"'))->'error'->>'code'='idempotency_conflict','payload conflict');
 bad:=req||jsonb_build_object('operationID',gen_random_uuid(),'id',gen_random_uuid());
 PERFORM pg_temp.assert_true(app.api_v1_trips(jsonb_set(bad,'{trip,maxItems}','1'))->'error'->>'code'='validation_failed','limit enforced by server');
 PERFORM pg_temp.assert_true(app.api_v1_trips(jsonb_set(bad,'{trip,days,0,outfitID}','"20000000-0000-0000-0000-000000000044"'))->'error'->>'code'='version_conflict','foreign outfit denied');
 PERFORM pg_temp.assert_true(app.api_v1_trips(jsonb_set(bad,'{trip,days,0,outfitVersion}','2'))->'error'->>'code'='version_conflict','stale outfit denied');
 PERFORM pg_temp.assert_true(app.api_v1_trips(jsonb_set(bad,'{trip,days,1,day}','"2026-11-05"'))->'error'->>'code'='validation_failed','duplicate day denied');
 PERFORM pg_temp.assert_true(app.api_v1_trips(jsonb_set(bad,'{trip,endsOn}','"2026-12-10"'))->'error'->>'code'='validation_failed','unbounded range denied');
 PERFORM pg_temp.assert_true(app.api_v1_trips(req||jsonb_build_object('user_id',gen_random_uuid(),'operationID',gen_random_uuid()))->'error'->>'code'='validation_failed','owner override denied');
 packed:=jsonb_build_object('action','pack','operationID',gen_random_uuid(),'id',req->'id','baseVersion',1,'garmentID','10000000-0000-0000-0000-000000000043','packed',true);
 result:=app.api_v1_trips(packed);
 PERFORM pg_temp.assert_true(result->'data'->>'version'='2','packing optimistic version');
 PERFORM pg_temp.assert_true(result->'data'->'packing'->0->>'packed'='true','packed saved');
 PERFORM pg_temp.assert_true(app.api_v1_trips(packed)=result,'packing replay');
 PERFORM pg_temp.assert_true((SELECT count(*) FROM app.wear_events)=0 AND (SELECT count(*) FROM app.wear_event_items)=0,'packing never counts wear or CPW');
 PERFORM pg_temp.assert_true(app.api_v1_trips(packed||jsonb_build_object('operationID',gen_random_uuid(),'packed',false))->'error'->>'code'='version_conflict','stale checklist update rejected');
 result:=app.api_v1_trips(packed||jsonb_build_object('operationID',gen_random_uuid(),'baseVersion',2,'packed',false));
 PERFORM pg_temp.assert_true(result->'data'->'packing'->0->>'packed'='false','undo only changes packing');
 -- Empty day is explicit, not a fabricated outfit or purchased garment.
 bad:=jsonb_set(jsonb_set(bad,'{trip,days,1,outfitID}','null'),'{trip,days,1,outfitVersion}','null');
 result:=app.api_v1_trips(bad);
 PERFORM pg_temp.assert_true(result->'data'->'days'->1->'garments'='[]' AND result->'data'->'days'->1->'missingCategories'='["top","bottom","shoes"]','empty day has explicit missing categories');
 -- Editing the trip preserves packing on unchanged garment IDs.
 result:=app.api_v1_trips(req||jsonb_build_object('operationID',gen_random_uuid(),'baseVersion',3));
 PERFORM pg_temp.assert_true(result->'data'->>'version'='4','editable dates and selection');
END $$;
RESET ROLE;
UPDATE app.garments SET availability='laundry' WHERE id='10000000-0000-0000-0000-000000000044';
SET LOCAL ROLE authenticated;
DO $$ DECLARE r jsonb;
BEGIN
 r:=app.api_v1_trips('{"action":"get","id":"30000000-0000-0000-0000-000000000043"}')->'data';
 PERFORM pg_temp.assert_true(r->'days'->0->'missingCategories'='["shoes"]','availability change yields explicit missing shoes');
 PERFORM pg_temp.assert_true(jsonb_array_length(r->'days'->0->'unavailableIDs')=1,'unavailable owned item flagged');
 PERFORM pg_temp.assert_true(app.api_v1_trips(jsonb_build_object('action','pack','operationID',gen_random_uuid(),'id','30000000-0000-0000-0000-000000000043','baseVersion',4,'garmentID','10000000-0000-0000-0000-000000000044','packed',true))->'error'->>'code'='validation_failed','cannot newly pack unavailable garment');
END $$;
SELECT app.api_v1_delete_garment(jsonb_build_object('operationID',gen_random_uuid(),'garmentID','10000000-0000-0000-0000-000000000043'));
SELECT pg_temp.assert_true(jsonb_array_length(app.api_v1_trips('{"action":"get","id":"30000000-0000-0000-0000-000000000043"}')->'data'->'days'->0->'unavailableIDs')=2,'deleted garment becomes an explicit gap');
SET LOCAL request.jwt.claim.sub='00000000-0000-0000-0000-000000000044';
SELECT pg_temp.assert_true(app.api_v1_trips('{"action":"get","id":"30000000-0000-0000-0000-000000000043"}')->'error'->>'code'='not_found','foreign trip hidden');
SELECT pg_temp.assert_true(app.api_v1_trips('{"action":"list"}')->'data'->'items'='[]','owner-only list');
SELECT pg_temp.assert_true(app.api_v1_trips(jsonb_build_object('action','pack','operationID',gen_random_uuid(),'id','30000000-0000-0000-0000-000000000043','baseVersion',4,'garmentID','10000000-0000-0000-0000-000000000045','packed',true))->'error'->>'code'='version_conflict','foreign trip packing blocked even with own garment');
RESET ROLE;
SELECT pg_temp.assert_true(api_private.export_snapshot('00000000-0000-0000-0000-000000000043')->'trips'->0 ?& ARRAY['max_items','timezone','days'],'trip fields included in owned data export');
ROLLBACK;
