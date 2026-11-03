BEGIN;
CREATE FUNCTION pg_temp.assert_true(ok boolean, message text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF ok IS DISTINCT FROM true THEN RAISE EXCEPTION 'Assertion failed: %', message; END IF; END $$;
INSERT INTO auth.users VALUES ('00000000-0000-0000-0000-000000000091'),('00000000-0000-0000-0000-000000000092');
INSERT INTO app.profiles(id,user_id) SELECT id,id FROM auth.users WHERE id IN ('00000000-0000-0000-0000-000000000091','00000000-0000-0000-0000-000000000092');
INSERT INTO app.garments(id,user_id,name,category,price_grosz)
SELECT ('10000000-0000-0000-0000-' || lpad(n::text,12,'0'))::uuid,
    '00000000-0000-0000-0000-000000000091', 'Item ' || lpad(n::text,4,'0'), 'top', n
FROM generate_series(1,1000) n;
INSERT INTO app.garments(id,user_id,name,category) VALUES
    ('20000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000092','Foreign','shoes');
INSERT INTO app.wear_events(id,user_id,worn_on,timezone,client_request_id)
SELECT ('30000000-0000-0000-0000-' || lpad(n::text,12,'0'))::uuid,
    '00000000-0000-0000-0000-000000000091','2026-01-01','Europe/Warsaw',gen_random_uuid()
FROM generate_series(1,2) n;
INSERT INTO app.wear_event_items(user_id,wear_event_id,garment_id)
SELECT user_id,id,'10000000-0000-0000-0000-000000000001' FROM app.wear_events
WHERE user_id = '00000000-0000-0000-0000-000000000091';
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claim.sub = '00000000-0000-0000-0000-000000000091';
DO $$ DECLARE
    request jsonb := '{"query":{"search":"","sort":"name","archived":false},"offset":0,"limit":40}';
    page jsonb;
    seen uuid[] := '{}';
    offset_value integer := 0;
    item jsonb;
BEGIN
    LOOP
        page := app.api_v1_browse_wardrobe(jsonb_set(request,'{offset}',to_jsonb(offset_value)));
        PERFORM pg_temp.assert_true(jsonb_array_length(page->'data'->'items') = 40, 'bounded page');
        FOR item IN SELECT value FROM jsonb_array_elements(page->'data'->'items') LOOP
            PERFORM pg_temp.assert_true(NOT (item->>'id')::uuid = ANY(seen), 'no repeated IDs');
            seen := array_append(seen,(item->>'id')::uuid);
            PERFORM pg_temp.assert_true(NOT item ?| ARRAY['original','object_key','url'], 'no original image or capability in page');
        END LOOP;
        EXIT WHEN page->'data'->>'nextOffset' IS NULL;
        offset_value := (page->'data'->>'nextOffset')::integer;
    END LOOP;
    PERFORM pg_temp.assert_true(cardinality(seen) = 1000, 'all 1000 owner items exactly once');
    page := app.api_v1_browse_wardrobe(jsonb_set(request,'{query,search}','"Item 1000"'));
    PERFORM pg_temp.assert_true(jsonb_array_length(page->'data'->'items') = 1, 'search across entire wardrobe');
    page := app.api_v1_browse_wardrobe(jsonb_set(request,'{query,search}','"%"'));
    PERFORM pg_temp.assert_true(page->'data'->'items' = '[]', 'literal search');
    page := app.api_v1_browse_wardrobe(jsonb_set(request,'{query,category}','"shoes"'));
    PERFORM pg_temp.assert_true(page->'data'->'items' = '[]', 'category and foreign isolation');
    page := app.api_v1_browse_wardrobe(jsonb_set(request,'{query,availability}','"laundry"'));
    PERFORM pg_temp.assert_true(page->'data'->'items' = '[]', 'availability filter');
    page := app.api_v1_browse_wardrobe(jsonb_set(request,'{query,archived}','true'));
    PERFORM pg_temp.assert_true(page->'data'->'items' = '[]', 'archive separate');
    page := app.api_v1_browse_wardrobe(jsonb_set(request,'{query,sort}','"nameDescending"'));
    PERFORM pg_temp.assert_true(page->'data'->'items'->0->>'name' = 'Item 1000', 'descending sort');
    page := app.api_v1_browse_wardrobe(jsonb_set(request,'{query,sort}','"price"'));
    PERFORM pg_temp.assert_true(page->'data'->'items'->0->>'priceGrosz' = '1', 'price sort');
    page := app.api_v1_browse_wardrobe(jsonb_set(request,'{limit}','101'));
    PERFORM pg_temp.assert_true(page->'error'->>'code' = 'validation_failed', 'page limit enforced');
    page := app.api_v1_sync_snapshot('{}');
    PERFORM pg_temp.assert_true(page->'data'->'garments'->0->'metadata'->>'archived' = 'false', 'sync carries display metadata');
    page := app.api_v1_garment_detail('{"id":"10000000-0000-0000-0000-000000000001"}');
    PERFORM pg_temp.assert_true(page->'data'->'wornOn' = '["2026-01-01"]', 'duplicate same-day wears count once');
    page := app.api_v1_garment_detail('{"id":"20000000-0000-0000-0000-000000000001"}');
    PERFORM pg_temp.assert_true(page->'error'->>'code' = 'not_found', 'foreign detail denied');
END $$;
RESET ROLE;
UPDATE app.wear_events SET deleted_at = now() WHERE id = '30000000-0000-0000-0000-000000000001';
SET LOCAL ROLE authenticated;
SELECT pg_temp.assert_true(app.api_v1_garment_detail('{"id":"10000000-0000-0000-0000-000000000001"}')->'data'->'wornOn' = '["2026-01-01"]', 'undo one event preserves second event');
RESET ROLE;
UPDATE app.profiles SET deleted_at = now() WHERE user_id = '00000000-0000-0000-0000-000000000091';
SET LOCAL ROLE authenticated;
SELECT pg_temp.assert_true(app.api_v1_browse_wardrobe('{"query":{"search":"","sort":"name","archived":false},"offset":0,"limit":40}')->'error'->>'code' = 'account_unavailable', 'deleted account denied');
ROLLBACK;
