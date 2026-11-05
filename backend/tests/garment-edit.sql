BEGIN;
CREATE FUNCTION pg_temp.assert_true(ok boolean, message text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF ok IS DISTINCT FROM true THEN RAISE EXCEPTION 'Assertion failed: %', message; END IF; END $$;
INSERT INTO auth.users VALUES ('00000000-0000-0000-0000-000000000091');
INSERT INTO app.profiles(id,user_id) VALUES ('00000000-0000-0000-0000-000000000091','00000000-0000-0000-0000-000000000091');
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000091',true);
DO $$
DECLARE
 request jsonb := '{"operation_id":"00000000-0000-0000-0000-000000000001","garment_id":"00000000-0000-0000-0000-000000000011","base_version":null,"garment":{"name":"Original","category":"top","price_grosz":null,"availability":"laundry","archived":true,"metadata":{"colors":["blue"],"seasons":["winter"],"pattern":"stripes","formality":4,"brand":"Brand","purchased_on":"2026-01-01"}}}';
 response jsonb; detail jsonb; metadata jsonb;
BEGIN
 response := app.api_v1_save_garment(request);
 PERFORM pg_temp.assert_true(response->'data'->>'version'='1','create existing fixture');
 detail := app.api_v1_garment_detail('{"id":"00000000-0000-0000-0000-000000000011"}');
 PERFORM pg_temp.assert_true(detail->'data'->'garment'->'formMetadata'=request->'garment'->'metadata','read all original fields without loss');
 PERFORM pg_temp.assert_true(detail->'data'->'garment'->>'version'='1','editor receives version');
 request := jsonb_set(jsonb_set(request,'{operation_id}','"00000000-0000-0000-0000-000000000002"'),'{base_version}','1');
 metadata := '{"colors":["red"],"seasons":["autumn"],"pattern":"plain","formality":2,"brand":null,"purchased_on":"2025-12-12"}';
 request := jsonb_set(jsonb_set(jsonb_set(request,'{garment,metadata}',metadata),'{garment,name}','"Updated"'),'{garment,price_grosz}','0');
 response := app.api_v1_save_garment(request);
 PERFORM pg_temp.assert_true(response->'data'->>'version'='2','existing item increments version');
 PERFORM pg_temp.assert_true(app.api_v1_save_garment(request)=response,'retry returns exact edit result');
 detail := app.api_v1_garment_detail('{"id":"00000000-0000-0000-0000-000000000011"}')->'data'->'garment';
 PERFORM pg_temp.assert_true(detail->'formMetadata'=metadata AND detail->>'name'='Updated' AND detail->>'priceGrosz'='0','updated read model retains complete edit and known zero');
 PERFORM pg_temp.assert_true(detail->>'availability'='laundry' AND detail->>'archived'='true','editing attributes retains status');
 detail := app.api_v1_sync_snapshot('{}')->'data'->'garments'->0->'metadata';
 PERFORM pg_temp.assert_true(detail->'formMetadata'=metadata AND detail->>'version'='2','second device snapshot receives full editor payload');
 PERFORM pg_temp.assert_true((SELECT count(*)=1 FROM app.garments),'edit does not create second item');
END $$;
ROLLBACK;
