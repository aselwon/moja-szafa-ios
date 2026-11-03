BEGIN;
CREATE FUNCTION pg_temp.assert_true(ok boolean, message text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF ok IS DISTINCT FROM true THEN RAISE EXCEPTION 'Assertion failed: %', message; END IF; END $$;
INSERT INTO auth.users VALUES ('00000000-0000-0000-0000-000000000081'),('00000000-0000-0000-0000-000000000082');
INSERT INTO app.profiles(id,user_id) SELECT id,id FROM auth.users WHERE id IN ('00000000-0000-0000-0000-000000000081','00000000-0000-0000-0000-000000000082');
INSERT INTO app.garments(id,user_id,name,category,archived_at) VALUES
 ('10000000-0000-0000-0000-000000000081','00000000-0000-0000-0000-000000000081','Archived shirt','top',now()),
 ('10000000-0000-0000-0000-000000000082','00000000-0000-0000-0000-000000000081','Dress','dress',NULL),
 ('10000000-0000-0000-0000-000000000083','00000000-0000-0000-0000-000000000082','Foreign','shoes',NULL);
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claim.sub = '00000000-0000-0000-0000-000000000081';
DO $$ DECLARE
 req jsonb := '{"operationID":"20000000-0000-0000-0000-000000000081","id":"30000000-0000-0000-0000-000000000081","baseVersion":0,"name":"Work","favorite":false,"garmentIDs":["10000000-0000-0000-0000-000000000081"]}';
 result jsonb;
BEGIN
 result := app.api_v1_save_outfit(req);
 PERFORM pg_temp.assert_true(result->'data'->>'version' = '1','create version');
 PERFORM pg_temp.assert_true(result->'data'->'garments'->0->>'archived' = 'true','archive warning metadata');
 PERFORM pg_temp.assert_true(app.api_v1_save_outfit(req) = result,'timeout replay');
 PERFORM pg_temp.assert_true(app.api_v1_save_outfit(jsonb_set(req,'{name}','"Different"'))->'error'->>'code' = 'idempotency_conflict','reject changed retry');
END $$;
RESET ROLE;
INSERT INTO app.wear_events(id,user_id,worn_on,timezone,client_request_id,source_outfit_id) VALUES
 ('40000000-0000-0000-0000-000000000081','00000000-0000-0000-0000-000000000081','2026-01-01','Europe/Warsaw',gen_random_uuid(),'30000000-0000-0000-0000-000000000081');
INSERT INTO app.wear_event_items(user_id,wear_event_id,garment_id) VALUES
 ('00000000-0000-0000-0000-000000000081','40000000-0000-0000-0000-000000000081','10000000-0000-0000-0000-000000000081');
SET LOCAL ROLE authenticated;
DO $$ DECLARE
 req jsonb := '{"operationID":"20000000-0000-0000-0000-000000000082","id":"30000000-0000-0000-0000-000000000081","baseVersion":1,"name":"Weekend","favorite":true,"garmentIDs":["10000000-0000-0000-0000-000000000082"]}';
 result jsonb;
 bad jsonb;
BEGIN
 result := app.api_v1_save_outfit(req);
 PERFORM pg_temp.assert_true(result->'data'->>'version' = '2' AND result->'data'->>'favorite' = 'true' AND result->'data'->>'name' = 'Weekend','edit and favorite');
 PERFORM pg_temp.assert_true((SELECT count(*) FROM app.wear_event_items WHERE garment_id = '10000000-0000-0000-0000-000000000081') = 1,'history unchanged');
 PERFORM pg_temp.assert_true(app.api_v1_save_outfit(jsonb_set(req,'{operationID}',to_jsonb(gen_random_uuid())))->'error'->>'code' = 'version_conflict','stale edit');
 bad := jsonb_set(jsonb_set(req,'{operationID}',to_jsonb(gen_random_uuid())),'{baseVersion}','2');
 PERFORM pg_temp.assert_true(app.api_v1_save_outfit(jsonb_set(bad,'{garmentIDs}','["10000000-0000-0000-0000-000000000083"]'))->'error'->>'code' = 'validation_failed','foreign garment');
 PERFORM pg_temp.assert_true(app.api_v1_save_outfit(jsonb_set(bad,'{garmentIDs}','[]'))->'error'->>'code' = 'validation_failed','empty selection');
 PERFORM pg_temp.assert_true(app.api_v1_save_outfit(jsonb_set(bad,'{garmentIDs}','["10000000-0000-0000-0000-000000000082","10000000-0000-0000-0000-000000000082"]'))->'error'->>'code' = 'validation_failed','duplicates');
 PERFORM pg_temp.assert_true(app.api_v1_list_outfits('{"limit":40,"cursor":null}')->'data'->'items'->0 = result->'data','list persisted edit');
END $$;
SET LOCAL request.jwt.claim.sub = '00000000-0000-0000-0000-000000000082';
SELECT pg_temp.assert_true(app.api_v1_list_outfits('{"limit":40,"cursor":null}')->'data'->'items' = '[]','owner isolation');
SELECT pg_temp.assert_true(app.api_v1_save_outfit('{"operationID":"20000000-0000-0000-0000-000000000084","id":"30000000-0000-0000-0000-000000000081","baseVersion":2,"name":"Foreign edit","favorite":false,"garmentIDs":["10000000-0000-0000-0000-000000000083"]}')->'error'->>'code' = 'version_conflict','foreign outfit edit denied');
ROLLBACK;
