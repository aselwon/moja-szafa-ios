BEGIN;
CREATE FUNCTION pg_temp.assert_true(ok boolean, message text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF ok IS DISTINCT FROM true THEN RAISE EXCEPTION 'Assertion failed: %', message; END IF; END $$;
INSERT INTO auth.users VALUES ('00000000-0000-0000-0000-000000000091'),('00000000-0000-0000-0000-000000000092');
INSERT INTO app.profiles(id,user_id) SELECT id,id FROM auth.users WHERE id IN ('00000000-0000-0000-0000-000000000091','00000000-0000-0000-0000-000000000092');
INSERT INTO app.garments(id,user_id,name,category,archived_at) VALUES
 ('10000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000091','Shirt','top',NULL),
 ('10000000-0000-0000-0000-000000000002','00000000-0000-0000-0000-000000000091','Archive','top',now()),
 ('10000000-0000-0000-0000-000000000003','00000000-0000-0000-0000-000000000092','Foreign','top',NULL);
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claim.sub = '00000000-0000-0000-0000-000000000091';
DO $$ DECLARE
 req jsonb := '{"operation_id":"20000000-0000-0000-0000-000000000001","outfit_id":"30000000-0000-0000-0000-000000000001","base_version":null,"outfit":{"name":"Work","favorite":false,"garmentIDs":["10000000-0000-0000-0000-000000000001"]}}';
 result jsonb;
BEGIN
 result := app.api_v1_save_outfit(req);
 PERFORM pg_temp.assert_true(result->'data'->>'version' = '1','create succeeds');
 PERFORM pg_temp.assert_true(app.api_v1_save_outfit(req) = result,'timeout replay identical');
 PERFORM pg_temp.assert_true(app.api_v1_save_outfit(jsonb_set(req,'{outfit,name}','"Changed"'))->'error'->>'code' = 'idempotency_conflict','different intent cannot reuse UUID');
 PERFORM pg_temp.assert_true(jsonb_array_length(app.api_v1_list_outfits('{}')->'data') = 1,'list saved outfit');
END $$;
RESET ROLE;
INSERT INTO app.wear_events(id,user_id,worn_on,timezone,client_request_id,source_outfit_id)
VALUES ('40000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000091','2026-01-01','Europe/Warsaw',gen_random_uuid(),'30000000-0000-0000-0000-000000000001');
INSERT INTO app.wear_event_items(user_id,wear_event_id,garment_id) VALUES
 ('00000000-0000-0000-0000-000000000091','40000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000001');
CREATE TEMP TABLE history_before AS SELECT to_jsonb(i) AS item FROM app.wear_event_items i;
SET LOCAL ROLE authenticated;
DO $$ DECLARE
 req jsonb := '{"operation_id":"20000000-0000-0000-0000-000000000002","outfit_id":"30000000-0000-0000-0000-000000000001","base_version":1,"outfit":{"name":"Weekend","favorite":true,"garmentIDs":["10000000-0000-0000-0000-000000000002"]}}';
 result jsonb;
BEGIN
 result := app.api_v1_save_outfit(req);
 PERFORM pg_temp.assert_true(result->'data'->>'version' = '2','edit increments version');
 PERFORM pg_temp.assert_true(result->'data'->>'favorite' = 'true','favorite persisted');
 PERFORM pg_temp.assert_true(result->'data'->>'name' = 'Weekend','rename persisted');
 PERFORM pg_temp.assert_true(result->'data'->'garmentIDs' = req->'outfit'->'garmentIDs','membership replaced with archive');
 PERFORM pg_temp.assert_true(app.api_v1_save_outfit(req) = result,'edit replay does not increment version');
 req := jsonb_set(req,'{operation_id}',to_jsonb(gen_random_uuid()));
 PERFORM pg_temp.assert_true(app.api_v1_save_outfit(req)->'error'->>'code' = 'version_conflict','stale edit rejected');
 req := jsonb_set(req,'{base_version}','2');
 req := jsonb_set(req,'{outfit,garmentIDs}','["10000000-0000-0000-0000-000000000003"]');
 PERFORM pg_temp.assert_true(app.api_v1_save_outfit(req)->'error'->>'code' = 'validation_failed','foreign item rejected');
 req := jsonb_set(req,'{outfit,garmentIDs}','["10000000-0000-0000-0000-000000000001","10000000-0000-0000-0000-000000000001"]');
 PERFORM pg_temp.assert_true(app.api_v1_save_outfit(req)->'error'->>'code' = 'validation_failed','duplicate item rejected');
 req := jsonb_set(req,'{outfit,garmentIDs}','[]');
 PERFORM pg_temp.assert_true(app.api_v1_save_outfit(req)->'error'->>'code' = 'validation_failed','empty selection rejected');
 PERFORM pg_temp.assert_true(app.api_v1_list_outfits('{}')->'data'->0->>'version' = '2','failed edits atomic');
 PERFORM pg_temp.assert_true(app.api_v1_garment_detail('{"id":"10000000-0000-0000-0000-000000000001"}')->'data'->'wornOn' = '["2026-01-01"]','original garment retains wear day');
 PERFORM pg_temp.assert_true(app.api_v1_garment_detail('{"id":"10000000-0000-0000-0000-000000000002"}')->'data'->'wornOn' = '[]','replacement has no invented wear');
END $$;
SET LOCAL request.jwt.claim.sub = '00000000-0000-0000-0000-000000000092';
SELECT pg_temp.assert_true(app.api_v1_list_outfits('{}')->'data' = '[]','foreign outfit hidden');
RESET ROLE;
SELECT pg_temp.assert_true((SELECT jsonb_agg(item) FROM history_before) = (SELECT jsonb_agg(to_jsonb(i)) FROM app.wear_event_items i),'historical membership byte-for-byte unchanged');
ROLLBACK;
