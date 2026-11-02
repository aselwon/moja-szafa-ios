BEGIN;
CREATE FUNCTION pg_temp.assert_form(ok boolean, message text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF ok IS DISTINCT FROM true THEN RAISE EXCEPTION 'Assertion failed: %', message; END IF; END $$;
INSERT INTO auth.users VALUES ('00000000-0000-0000-0000-000000000121');
INSERT INTO app.profiles(id,user_id) VALUES ('00000000-0000-0000-0000-000000000121','00000000-0000-0000-0000-000000000121');
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000121',true);
DO $$
DECLARE
    request jsonb := '{"operation_id":"00000000-0000-0000-0000-000000000122","garment_id":"00000000-0000-0000-0000-000000000123","base_version":null,"garment":{"name":"Dress","category":"dress","price_grosz":0,"availability":"available","colors":["blue","white"],"pattern":"plain","seasons":["summer"],"formality":3,"brand":"Brand","purchased_on":"2024-02-29"}}';
    result jsonb;
    fields jsonb;
    invalid jsonb;
BEGIN
    result := app.api_v1_save_garment(request);
    PERFORM pg_temp.assert_form(result->'data'->>'version' = '1','full form saved');
    PERFORM pg_temp.assert_form(result = app.api_v1_save_garment(request),'replay');
    fields := result->'data' - ARRAY['id','version'];
    PERFORM pg_temp.assert_form(fields = request->'garment','all fields returned');
    PERFORM pg_temp.assert_form(app.api_v1_list_garments('{"limit":50,"cursor":null}')->'data'->'items'->0 = result->'data','list projection');
    PERFORM pg_temp.assert_form(app.api_v1_sync_snapshot('{}')->'data'->'garments'->0->'fields' = fields,'sync projection');
    FOREACH invalid IN ARRAY ARRAY[
        '{"colors":null}'::jsonb,'{"colors":["blue","blue"]}','{"colors":[1]}',
        '{"seasons":["monsoon"]}','{"formality":6}','{"formality":1.5}',
        '{"purchased_on":"2025-02-29"}','{"purchased_on":"2024-2-1"}',
        '{"price_grosz":-1}','{"price_grosz":1.5}'
    ] LOOP
        PERFORM pg_temp.assert_form(app.api_v1_save_garment(jsonb_set(request,'{garment}',fields || invalid))->'error'->>'code' = 'validation_failed','invalid metadata rejected');
    END LOOP;
    request := jsonb_set(jsonb_set(request,'{operation_id}',to_jsonb(gen_random_uuid())), '{base_version}', '1');
    request := jsonb_set(request,'{garment}',fields - ARRAY['colors','pattern','seasons','formality','brand','purchased_on']);
    result := app.api_v1_save_garment(request);
    PERFORM pg_temp.assert_form(result->'data' - ARRAY['id','version'] = fields,'legacy edit preserves metadata');
    request := jsonb_set(jsonb_set(request,'{operation_id}',to_jsonb(gen_random_uuid())), '{base_version}', '2');
    request := jsonb_set(request,'{garment}',fields || '{"colors":[],"pattern":null,"seasons":[],"formality":null,"brand":null,"purchased_on":null,"price_grosz":null}');
    result := app.api_v1_save_garment(request);
    PERFORM pg_temp.assert_form(result->'data' - ARRAY['id','version'] = request->'garment','explicit clearing and unknown price');
END $$;
ROLLBACK;
