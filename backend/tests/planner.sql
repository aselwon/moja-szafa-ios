BEGIN;
CREATE FUNCTION pg_temp.assert_true(ok boolean,message text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF ok IS DISTINCT FROM true THEN RAISE EXCEPTION 'Assertion failed: %',message; END IF; END $$;
INSERT INTO auth.users VALUES ('00000000-0000-0000-0000-000000000041'),('00000000-0000-0000-0000-000000000042');
INSERT INTO app.profiles(id,user_id) SELECT id,id FROM auth.users WHERE id IN ('00000000-0000-0000-0000-000000000041','00000000-0000-0000-0000-000000000042');
INSERT INTO app.garments(id,user_id,name,category,price_grosz) VALUES
 ('10000000-0000-0000-0000-000000000041','00000000-0000-0000-0000-000000000041','Shirt','top',10000),
 ('10000000-0000-0000-0000-000000000042','00000000-0000-0000-0000-000000000041','Shoes','shoes',20000);
INSERT INTO app.outfits(id,user_id,name) VALUES ('20000000-0000-0000-0000-000000000041','00000000-0000-0000-0000-000000000041','Work');
INSERT INTO app.outfit_items(user_id,outfit_id,garment_id,position) VALUES ('00000000-0000-0000-0000-000000000041','20000000-0000-0000-0000-000000000041','10000000-0000-0000-0000-000000000041',0);
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claim.sub='00000000-0000-0000-0000-000000000041';
DO $$ DECLARE
 today text := to_char(clock_timestamp() AT TIME ZONE 'Pacific/Honolulu','YYYY-MM-DD');
 tomorrow text := to_char((clock_timestamp() AT TIME ZONE 'Pacific/Honolulu')::date+1,'YYYY-MM-DD');
 plan uuid := '30000000-0000-0000-0000-000000000041';
 req jsonb; result jsonb; version bigint; wear uuid;
BEGIN
 req := jsonb_build_object('action','create','operationID',gen_random_uuid(),'id',plan,'baseVersion',0,'outfitID','20000000-0000-0000-0000-000000000041','day',tomorrow,'timezone','Pacific/Honolulu');
 result := app.api_v1_planner(req);
 PERFORM pg_temp.assert_true(result->'data'->>'day'=tomorrow,'future plan created in explicit local timezone');
 PERFORM pg_temp.assert_true(app.api_v1_planner(req)=result,'same-body replay');
 PERFORM pg_temp.assert_true(app.api_v1_planner(req||jsonb_build_object('day',today))->'error'->>'code'='idempotency_conflict','changed retry rejected');
 PERFORM pg_temp.assert_true((SELECT count(*) FROM app.wear_events)=0,'plan is not a wear');
 result := app.api_v1_planner(jsonb_build_object('action','confirm','outfitVersion',1,'operationID',gen_random_uuid(),'id',plan,'baseVersion',1));
 PERFORM pg_temp.assert_true(result->'error'->>'code'='validation_failed','future wear rejected');
 result := app.api_v1_planner(jsonb_build_object('action','move','operationID',gen_random_uuid(),'id',plan,'baseVersion',1,'day',today,'timezone','Pacific/Honolulu'));
 PERFORM pg_temp.assert_true(result->'data'->>'version'='2','move versions');
 PERFORM pg_temp.assert_true((SELECT count(*) FROM app.wear_events)=0,'move is not a wear');
 req := jsonb_build_object('action','confirm','outfitVersion',1,'operationID',gen_random_uuid(),'id',plan,'baseVersion',2);
 PERFORM pg_temp.assert_true(app.api_v1_planner(req||jsonb_build_object('outfitVersion',2))->'error'->>'code'='version_conflict','changed outfit requires review before confirming');
 result := app.api_v1_planner(req); wear := (result->'data'->>'wearID')::uuid;
 PERFORM pg_temp.assert_true(wear IS NOT NULL,'explicit confirmation creates wear');
 PERFORM pg_temp.assert_true(app.api_v1_planner(req)=result,'confirmation replay');
 PERFORM pg_temp.assert_true(app.api_v1_planner(req||jsonb_build_object('operationID',gen_random_uuid()))->'data'->>'wearID'=wear::text,'different operation same plan/day deduplicated');
 PERFORM pg_temp.assert_true((SELECT count(*) FROM app.wear_events)=1,'exactly one wear');
 PERFORM pg_temp.assert_true((SELECT worn_on::text=today AND timezone='Pacific/Honolulu' FROM app.wear_events WHERE id=wear),'local wear day preserved');
 result := app.api_v1_planner(jsonb_build_object('action','move','operationID',gen_random_uuid(),'id',plan,'baseVersion',2,'day',tomorrow,'timezone','Pacific/Honolulu'));
 PERFORM pg_temp.assert_true(result->'data'->'wearID'='null','moving does not transfer confirmation to another day');
 PERFORM pg_temp.assert_true((SELECT worn_on::text=today FROM app.wear_events WHERE id=wear),'move preserves historical date');
 result := app.api_v1_planner(jsonb_build_object('action','delete','operationID',gen_random_uuid(),'id',plan,'baseVersion',3));
 PERFORM pg_temp.assert_true(result->'data'->>'deleted'='true','soft delete');
 PERFORM pg_temp.assert_true((SELECT count(*) FROM app.wear_events)=1,'delete leaves CPW history');
 result := app.api_v1_planner(jsonb_build_object('action','restore','operationID',gen_random_uuid(),'id',plan,'baseVersion',4));
 PERFORM pg_temp.assert_true(result->'data'->>'deleted'='false','undo restore');
 PERFORM pg_temp.assert_true(app.api_v1_planner(jsonb_build_object('action','delete','operationID',gen_random_uuid(),'id',plan,'baseVersion',4))->'error'->>'code'='version_conflict','stale write rejected');
 PERFORM pg_temp.assert_true(jsonb_array_length(app.api_v1_planner(jsonb_build_object('action','list','from',today,'through',tomorrow))->'data'->'items')=1,'date range list');
 PERFORM pg_temp.assert_true(app.api_v1_planner(jsonb_build_object('action','list','from',today,'through',tomorrow,'user_id',gen_random_uuid()))->'error'->>'code'='validation_failed','owner override rejected');
END $$;
-- Editing the outfit after confirmation cannot rewrite the captured wear items.
SELECT app.api_v1_save_outfit('{"operationID":"40000000-0000-0000-0000-000000000041","id":"20000000-0000-0000-0000-000000000041","baseVersion":1,"name":"Edited","favorite":false,"garmentIDs":["10000000-0000-0000-0000-000000000042"]}');
SELECT pg_temp.assert_true((SELECT count(*)=1 FROM app.wear_event_items WHERE garment_id='10000000-0000-0000-0000-000000000041'),'historical membership immutable');
SET LOCAL request.jwt.claim.sub='00000000-0000-0000-0000-000000000042';
SELECT pg_temp.assert_true(app.api_v1_planner('{"action":"list","from":"2026-01-01","through":"2026-12-31"}')->'data'->'items'='[]','foreign list empty');
SELECT pg_temp.assert_true(app.api_v1_planner('{"action":"confirm","outfitVersion":1,"operationID":"40000000-0000-0000-0000-000000000042","id":"30000000-0000-0000-0000-000000000041","baseVersion":5}')->'error'->>'code'='version_conflict','foreign confirmation rejected');
SELECT pg_temp.assert_true(app.api_v1_planner(jsonb_build_object('action','create','operationID',gen_random_uuid(),'id',gen_random_uuid(),'baseVersion',0,'outfitID','20000000-0000-0000-0000-000000000041','day',current_date::text,'timezone','UTC'))->'error'->>'code'='validation_failed','foreign outfit cannot be planned');
RESET ROLE;
INSERT INTO app.planned_outfits(user_id,outfit_id,planned_on,timezone)
SELECT '00000000-0000-0000-0000-000000000041','20000000-0000-0000-0000-000000000041',current_date+n,'UTC' FROM generate_series(10,54) n;
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claim.sub='00000000-0000-0000-0000-000000000041';
DO $$ DECLARE req jsonb; first_page jsonb; second_page jsonb;
BEGIN
 req := jsonb_build_object('action','list','from',(current_date+10)::text,'through',(current_date+54)::text);
 first_page := app.api_v1_planner(req)->'data';
 PERFORM pg_temp.assert_true(jsonb_array_length(first_page->'items')=40 AND first_page->>'nextCursor' IS NOT NULL,'bounded first page');
 second_page := app.api_v1_planner(req||jsonb_build_object('cursor',first_page->'nextCursor'))->'data';
 PERFORM pg_temp.assert_true(jsonb_array_length(second_page->'items')=5 AND second_page->'nextCursor'='null','final page');
 PERFORM pg_temp.assert_true(NOT EXISTS(SELECT FROM jsonb_array_elements(first_page->'items') a JOIN jsonb_array_elements(second_page->'items') b ON a->>'id'=b->>'id'),'pages do not duplicate plans');
END $$;
ROLLBACK;
