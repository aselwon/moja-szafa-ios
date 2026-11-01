BEGIN;
CREATE FUNCTION pg_temp.assert_true(ok boolean, message text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF ok IS DISTINCT FROM true THEN RAISE EXCEPTION 'Assertion failed: %', message; END IF; END $$;
INSERT INTO auth.users VALUES ('00000000-0000-0000-0000-000000000091'),('00000000-0000-0000-0000-000000000092');
INSERT INTO app.profiles(id,user_id) SELECT id,id FROM auth.users WHERE id IN ('00000000-0000-0000-0000-000000000091','00000000-0000-0000-0000-000000000092');
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000091',true);
DO $$
DECLARE
    request jsonb := '{"operation_id":"00000000-0000-0000-0000-000000000001","garment_id":"00000000-0000-0000-0000-000000000011","base_version":null,"garment":{"name":"Koszula","category":"top","price_grosz":null,"availability":"available"}}';
    original jsonb;
    replay jsonb;
    changed jsonb;
    page jsonb;
BEGIN
    original := app.api_v1_save_garment(request);
    PERFORM pg_temp.assert_true(original->'data'->>'version' = '1', 'create version');
    PERFORM pg_temp.assert_true((original->>'request_id')::uuid IS NOT NULL, 'request ID');
    -- The caller discards the first response (commit-before-timeout scenario).
    replay := app.api_v1_save_garment(request);
    PERFORM pg_temp.assert_true(replay = original, 'replay exact original response');
    PERFORM pg_temp.assert_true((SELECT count(*) = 1 FROM app.garments), 'no duplicate');
    replay := app.api_v1_save_garment(jsonb_set(request,'{garment,name}','"Changed"'));
    PERFORM pg_temp.assert_true(replay->'error'->>'code' = 'idempotency_conflict', 'changed payload conflicts');
    changed := jsonb_set(jsonb_set(jsonb_set(request,'{operation_id}','"00000000-0000-0000-0000-000000000002"'),'{base_version}','1'),'{garment,price_grosz}','80000');
    replay := app.api_v1_save_garment(changed);
    PERFORM pg_temp.assert_true(replay->'data'->>'version' = '2', 'update version');
    PERFORM pg_temp.assert_true(app.api_v1_save_garment(changed) = replay, 'update replay does not increment version');
    PERFORM pg_temp.assert_true(app.api_v1_save_garment(request) = original, 'old replay returns original result after later edit');
    changed := jsonb_set(changed,'{operation_id}','"00000000-0000-0000-0000-000000000003"');
    replay := app.api_v1_save_garment(changed);
    PERFORM pg_temp.assert_true(replay->'error'->>'code' = 'version_conflict', 'stale update');
    replay := app.api_v1_save_garment(jsonb_set(changed,'{garment,price_grosz}','-1'));
    PERFORM pg_temp.assert_true(replay->'error'->>'code' = 'validation_failed', 'negative price');
    replay := app.api_v1_save_garment(request || '{"user_id":"00000000-0000-0000-0000-000000000092"}');
    PERFORM pg_temp.assert_true(replay->'error'->>'code' = 'validation_failed', 'cannot inject ownership');
    replay := app.api_v1_save_garment(jsonb_set(request,'{garment,price_grosz}','9223372036854775808'));
    -- This key already exists with a different payload; either way no mutation.
    PERFORM pg_temp.assert_true(replay->'error'->>'code' = 'idempotency_conflict', 'key comparison precedes save');
    changed := jsonb_set(jsonb_set(request,'{operation_id}','"00000000-0000-0000-0000-000000000004"'),'{garment_id}','"00000000-0000-0000-0000-000000000012"');
    replay := app.api_v1_save_garment(changed);
    PERFORM pg_temp.assert_true(replay ? 'data', 'second garment');
    page := app.api_v1_list_garments('{"limit":1,"cursor":null}');
    PERFORM pg_temp.assert_true(jsonb_array_length(page->'data'->'items') = 1 AND page->'data'->>'next_cursor' = request->>'garment_id','first page');
    page := app.api_v1_list_garments(jsonb_build_object('limit',1,'cursor',page->'data'->'next_cursor'));
    PERFORM pg_temp.assert_true(page->'data'->'items'->0->>'id' = changed->>'garment_id' AND page->'data'->'next_cursor' = 'null'::jsonb,'last page');
    page := app.api_v1_list_garments('{"limit":101,"cursor":null}');
    PERFORM pg_temp.assert_true(page->'error'->>'code' = 'validation_failed','bounded page size');
    page := app.api_v1_list_garments('{"limit":1,"cursor":"invalid"}');
    PERFORM pg_temp.assert_true(page->'error'->>'code' = 'validation_failed','invalid cursor');
    PERFORM set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000092',true);
    page := app.api_v1_list_garments('{"limit":100,"cursor":null}');
    PERFORM pg_temp.assert_true(page->'data'->'items' = '[]'::jsonb,'other owner sees no rows');
    changed := jsonb_set(request,'{base_version}','2');
    replay := app.api_v1_save_garment(changed);
    PERFORM pg_temp.assert_true(replay->'error'->>'code' = 'version_conflict','cannot update other owner');
    -- Same operation ID in another account is independent, no replay leakage.
    changed := jsonb_set(request,'{garment_id}','"00000000-0000-0000-0000-000000000013"');
    replay := app.api_v1_save_garment(changed);
    PERFORM pg_temp.assert_true(replay->'data'->>'id' = changed->>'garment_id','owner-scoped keys');
    PERFORM set_config('request.jwt.claim.sub','',true);
    replay := app.api_v1_save_garment(request);
    PERFORM pg_temp.assert_true(replay->'error'->>'code' = 'unauthorized','missing identity');
END $$;
RESET ROLE;
SELECT pg_temp.assert_true(NOT EXISTS (SELECT FROM api_private.mutations WHERE user_id = '00000000-0000-0000-0000-000000000091' AND operation_id = '00000000-0000-0000-0000-000000000003'),'failed mutation rolls back replay record');
-- Tombstones cannot be resurrected and deletion invalidates earlier successes.
UPDATE app.garments SET deleted_at = now() WHERE id = '00000000-0000-0000-0000-000000000011';
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000091',true);
SELECT pg_temp.assert_true(app.api_v1_save_garment('{"operation_id":"00000000-0000-0000-0000-000000000005","garment_id":"00000000-0000-0000-0000-000000000011","base_version":3,"garment":{"name":"Stale","category":"top","price_grosz":0,"availability":"available"}}')->'error'->>'code' = 'version_conflict','tombstone wins');
RESET ROLE;
UPDATE app.profiles SET deleted_at = now() WHERE user_id = '00000000-0000-0000-0000-000000000091';
SET LOCAL ROLE authenticated;
SELECT pg_temp.assert_true(app.api_v1_save_garment('{"operation_id":"00000000-0000-0000-0000-000000000001","garment_id":"00000000-0000-0000-0000-000000000011","base_version":null,"garment":{"name":"Koszula","category":"top","price_grosz":null,"availability":"available"}}')->'error'->>'code' = 'account_unavailable','account tombstone before replay');
RESET ROLE;
SELECT pg_temp.assert_true(NOT has_function_privilege('anon','app.api_v1_save_garment(jsonb)','EXECUTE'),'anonymous cannot mutate');
SELECT pg_temp.assert_true(NOT has_schema_privilege('authenticated','api_private','USAGE'),'ledger private');
ROLLBACK;
