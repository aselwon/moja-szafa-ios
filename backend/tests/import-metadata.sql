BEGIN;
CREATE FUNCTION pg_temp.assert_true(ok boolean, message text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF ok IS DISTINCT FROM true THEN RAISE EXCEPTION 'Assertion failed: %', message; END IF; END $$;
INSERT INTO auth.users VALUES ('00000000-0000-0000-0000-000000000091');
INSERT INTO app.profiles(id,user_id) VALUES ('00000000-0000-0000-0000-000000000091','00000000-0000-0000-0000-000000000091');
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000091',true);
DO $$
DECLARE
    request jsonb := '{"operation_id":"00000000-0000-0000-0000-000000000001","garment_id":"00000000-0000-0000-0000-000000000011","base_version":null,"garment":{"name":"Blue shirt","category":"top","price_grosz":4500,"availability":"available","metadata":{"colors":["blue"],"seasons":["summer"],"pattern":"stripes","formality":2,"brand":"Example","purchased_on":"2026-01-01"}}}';
    response jsonb;
    changed jsonb;
    invalid jsonb;
BEGIN
    response := app.api_v1_save_garment(request);
    PERFORM pg_temp.assert_true(response->'data'->>'version' = '1','import creates garment');
    PERFORM pg_temp.assert_true(app.api_v1_save_garment(request) = response,'timeout replay exact');
    PERFORM pg_temp.assert_true((SELECT colors=ARRAY['blue'] AND seasons=ARRAY['summer'] AND pattern='stripes'
      AND formality=2 AND brand='Example' AND purchased_on=DATE '2026-01-01' AND price_grosz=4500 FROM app.garments
      WHERE id='00000000-0000-0000-0000-000000000011'),'all form attributes stored');
    changed := jsonb_set(jsonb_set(request,'{operation_id}','"00000000-0000-0000-0000-000000000002"'),'{garment_id}','"00000000-0000-0000-0000-000000000012"');
    PERFORM pg_temp.assert_true(app.api_v1_save_garment(changed) ? 'data','keep identical second item');
    PERFORM pg_temp.assert_true((SELECT count(*)=2 FROM app.garments),'identical items remain distinct');
    changed := jsonb_set(jsonb_set(request #- '{garment,metadata}','{operation_id}','"00000000-0000-0000-0000-000000000003"'),'{base_version}','1');
    changed := jsonb_set(changed,'{garment,availability}','"laundry"');
    PERFORM pg_temp.assert_true(app.api_v1_save_garment(changed) ? 'data','older status edit succeeds');
    PERFORM pg_temp.assert_true((SELECT brand='Example' AND colors=ARRAY['blue'] AND pattern='stripes' AND availability='laundry'
      FROM app.garments WHERE id='00000000-0000-0000-0000-000000000011'),'older status edit preserves metadata');
    FOR invalid IN SELECT value FROM jsonb_array_elements('[{"colors":["invalid"]},{"colors":["blue","blue"]},{"seasons":[null]},{"formality":6},{"brand":42},{"purchased_on":"2026-02-30"},{"purchased_on":"9999-01-01"}]'::jsonb)
    LOOP
        changed := jsonb_set(request,'{garment,metadata}',request->'garment'->'metadata' || invalid);
        PERFORM pg_temp.assert_true(app.api_v1_save_garment(changed)->'error'->>'code'='validation_failed','invalid metadata rejected');
    END LOOP;
    PERFORM pg_temp.assert_true((SELECT count(*)=2 FROM app.garments),'invalid writes leave no rows');
END $$;
ROLLBACK;
