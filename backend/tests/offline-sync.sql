BEGIN;
CREATE FUNCTION pg_temp.assert_sync(ok boolean, message text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF ok IS DISTINCT FROM true THEN RAISE EXCEPTION 'Assertion failed: %', message; END IF; END $$;
INSERT INTO auth.users VALUES ('00000000-0000-0000-0000-000000000081'),('00000000-0000-0000-0000-000000000082');
INSERT INTO app.profiles(id,user_id) SELECT id,id FROM auth.users WHERE id IN ('00000000-0000-0000-0000-000000000081','00000000-0000-0000-0000-000000000082');
INSERT INTO app.garments(id,user_id,name,category) VALUES
('00000000-0000-0000-0000-000000000083','00000000-0000-0000-0000-000000000081','Own','top'),
('00000000-0000-0000-0000-000000000084','00000000-0000-0000-0000-000000000082','Foreign','shoes');
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000081',true);
DO $$
DECLARE
    request jsonb := '{"operationID":"00000000-0000-0000-0000-000000000085","wear":{"id":"00000000-0000-0000-0000-000000000086","version":0,"deleted":false,"wornOn":"2026-01-01","timezone":"Europe/Warsaw","garmentIDs":["00000000-0000-0000-0000-000000000083"]}}';
    result jsonb;
    changed jsonb;
BEGIN
    result := app.api_v1_save_wear(request);
    PERFORM pg_temp.assert_sync(result->'data'->>'version' = '1','wear created');
    PERFORM pg_temp.assert_sync(app.api_v1_save_wear(request) = result,'exact replay after lost response');
    PERFORM pg_temp.assert_sync((SELECT count(*) = 1 FROM app.wear_events),'no duplicate event');
    PERFORM pg_temp.assert_sync((SELECT count(*) = 1 FROM app.wear_event_items),'no duplicate relation');
    PERFORM pg_temp.assert_sync(app.api_v1_save_wear(jsonb_set(request,'{wear,wornOn}','"2026-01-02"'))->'error'->>'code' = 'idempotency_conflict','changed replay rejected');
    changed := jsonb_set(jsonb_set(request,'{operationID}','"00000000-0000-0000-0000-000000000087"'),'{wear,id}','"00000000-0000-0000-0000-000000000088"');
    PERFORM pg_temp.assert_sync(app.api_v1_save_wear(changed) ? 'data','independent event same day');
    PERFORM pg_temp.assert_sync((SELECT count(DISTINCT worn_on) = 1 FROM app.wear_events),'unique local day');
    changed := jsonb_set(jsonb_set(request,'{operationID}','"00000000-0000-0000-0000-000000000089"'),'{wear,id}','"00000000-0000-0000-0000-000000000080"');
    PERFORM pg_temp.assert_sync(app.api_v1_save_wear(jsonb_set(changed,'{wear,wornOn}','"2999-01-01"'))->'error'->>'code' = 'validation_failed','future is not wear');
    PERFORM pg_temp.assert_sync(app.api_v1_save_wear(jsonb_set(changed,'{wear,garmentIDs}','["00000000-0000-0000-0000-000000000084"]'))->'error'->>'code' = 'validation_failed','foreign garment rejected');
    PERFORM pg_temp.assert_sync(app.api_v1_save_wear(jsonb_set(changed,'{wear,garmentIDs}','["00000000-0000-0000-0000-000000000083","00000000-0000-0000-0000-000000000083"]'))->'error'->>'code' = 'validation_failed','duplicate IDs rejected');
    PERFORM pg_temp.assert_sync((SELECT count(*) = 2 FROM app.wear_events), 'rejected writes leave no events');
    PERFORM pg_temp.assert_sync((SELECT count(*) = 2 FROM app.wear_event_items), 'rejected writes leave no items');
    result := app.api_v1_sync_snapshot('{}');
    PERFORM pg_temp.assert_sync(jsonb_array_length(result->'data'->'garments') = 1,'owner scoped snapshot');
    PERFORM pg_temp.assert_sync(jsonb_array_length(result->'data'->'wears') = 2,'history included');
    PERFORM set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000082',true);
    PERFORM pg_temp.assert_sync(app.api_v1_sync_snapshot('{}')->'data'->'wears' = '[]'::jsonb,'foreign history invisible');
END $$;
RESET ROLE;
UPDATE app.garments SET deleted_at = now() WHERE id = '00000000-0000-0000-0000-000000000083';
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000081',true);
SELECT pg_temp.assert_sync(app.api_v1_sync_snapshot('{}')->'data'->'garments'->0->>'deleted' = 'true','tombstone delivered');
SELECT pg_temp.assert_sync(app.api_v1_sync_snapshot('{}')->'data'->'garments'->0->>'version' = '2','tombstone version');
RESET ROLE;
UPDATE app.profiles SET deleted_at = now() WHERE user_id = '00000000-0000-0000-0000-000000000081';
SET LOCAL ROLE authenticated;
SELECT pg_temp.assert_sync(app.api_v1_sync_snapshot('{}')->'error'->>'code' = 'account_unavailable','account deletion fences pulls');
SELECT pg_temp.assert_sync(app.api_v1_save_wear('{"operationID":"00000000-0000-0000-0000-000000000085","wear":{"id":"00000000-0000-0000-0000-000000000086","version":0,"deleted":false,"wornOn":"2026-01-01","timezone":"Europe/Warsaw","garmentIDs":["00000000-0000-0000-0000-000000000083"]}}')->'error'->>'code' = 'account_unavailable','deletion wins over replay');
ROLLBACK;
