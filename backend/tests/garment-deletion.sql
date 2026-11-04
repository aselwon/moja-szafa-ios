BEGIN;
CREATE FUNCTION pg_temp.assert_true(ok boolean, message text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF ok IS DISTINCT FROM true THEN RAISE EXCEPTION 'Assertion failed: %', message; END IF; END $$;
INSERT INTO auth.users VALUES ('00000000-0000-0000-0000-000000000081'),('00000000-0000-0000-0000-000000000082');
INSERT INTO app.profiles(id,user_id) VALUES ('00000000-0000-0000-0000-000000000081','00000000-0000-0000-0000-000000000081');
INSERT INTO app.garments(id,user_id,name,category,price_grosz) VALUES
 ('10000000-0000-0000-0000-000000000081','00000000-0000-0000-0000-000000000081','Shirt','top',80000);
INSERT INTO app.wear_events(id,user_id,worn_on,timezone,client_request_id) VALUES
 ('20000000-0000-0000-0000-000000000081','00000000-0000-0000-0000-000000000081','2026-01-01','Europe/Warsaw',gen_random_uuid());
INSERT INTO app.wear_event_items(user_id,wear_event_id,garment_id) VALUES
 ('00000000-0000-0000-0000-000000000081','20000000-0000-0000-0000-000000000081','10000000-0000-0000-0000-000000000081');
INSERT INTO api_private.image_uploads(id,user_id,garment_id,state) VALUES
 ('30000000-0000-0000-0000-000000000081','00000000-0000-0000-0000-000000000081','10000000-0000-0000-0000-000000000081','ready');
INSERT INTO app.profiles(id,user_id) VALUES ('00000000-0000-0000-0000-000000000082','00000000-0000-0000-0000-000000000082');
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claim.sub = '00000000-0000-0000-0000-000000000081';
DO $$ DECLARE
 request jsonb := '{"operationID":"40000000-0000-0000-0000-000000000081","garmentID":"10000000-0000-0000-0000-000000000081"}';
 result jsonb;
BEGIN
 result := app.api_v1_delete_garment(request);
 PERFORM pg_temp.assert_true(result->'data' = 'true', 'delete success');
 PERFORM pg_temp.assert_true(app.api_v1_delete_garment(request) = result, 'exact replay');
 PERFORM pg_temp.assert_true(EXISTS(SELECT FROM app.garments WHERE id=(request->>'garmentID')::uuid AND deleted_at IS NOT NULL AND price_grosz IS NULL), 'scrubbed tombstone');
 PERFORM pg_temp.assert_true(NOT EXISTS(SELECT FROM app.wear_event_items WHERE garment_id=(request->>'garmentID')::uuid), 'history membership removed');
 result := app.api_v1_save_garment('{"operation_id":"50000000-0000-0000-0000-000000000081","garment_id":"10000000-0000-0000-0000-000000000081","base_version":null,"garment":{"name":"Revived","category":"top","price_grosz":null,"availability":"available"}}');
 PERFORM pg_temp.assert_true(result->'error'->>'code' = 'version_conflict', 'stale create cannot revive');
END $$;
RESET ROLE;
SELECT pg_temp.assert_true(app.images_command('{"action":"sweep"}') @> '[{"id":"30000000-0000-0000-0000-000000000081"}]', 'durable photo cleanup scheduled');
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claim.sub = '00000000-0000-0000-0000-000000000082';
SELECT pg_temp.assert_true(app.api_v1_delete_garment('{"operationID":"60000000-0000-0000-0000-000000000081","garmentID":"10000000-0000-0000-0000-000000000081"}')->'error'->>'code' = 'validation_failed', 'foreign garment rejected');
ROLLBACK;
