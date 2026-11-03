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
    mutation jsonb;
    saved jsonb;
    status text;
    archive boolean;
    current_version bigint := 1;
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
    FOREACH status IN ARRAY ARRAY['available','laundry','unavailable'] LOOP
        FOREACH archive IN ARRAY ARRAY[true,false] LOOP
            mutation := jsonb_build_object('operation_id',gen_random_uuid(),
                'garment_id','10000000-0000-0000-0000-000000000001','base_version',current_version,
                'garment',jsonb_build_object('name','Item 0001','category','top','price_grosz',1,
                    'availability',status,'archived',archive));
            saved := app.api_v1_save_garment(mutation);
            current_version := current_version + 1;
            PERFORM pg_temp.assert_true((saved->'data'->>'version')::bigint = current_version, 'status version increments');
            PERFORM pg_temp.assert_true(app.api_v1_save_garment(mutation) = saved, 'status replay is idempotent');
            page := app.api_v1_garment_detail('{"id":"10000000-0000-0000-0000-000000000001"}');
            PERFORM pg_temp.assert_true(page->'data'->'garment'->>'availability' = status, 'availability independent of archive');
            PERFORM pg_temp.assert_true((page->'data'->'garment'->>'archived')::boolean = archive, 'archive and restore');
            PERFORM pg_temp.assert_true(page->'data'->'garment'->>'priceGrosz' = '1' AND
                page->'data'->'wornOn' = '["2026-01-01"]', 'CPW inputs and history unchanged');
            page := app.api_v1_sync_snapshot('{}');
            PERFORM pg_temp.assert_true((page->'data'->'garments'->0->'fields'->>'archived')::boolean = archive AND
                page->'data'->'garments'->0->'fields'->>'availability' = status, 'second device snapshot carries both states');
            mutation := jsonb_set(mutation,'{operation_id}',to_jsonb(gen_random_uuid()));
            PERFORM pg_temp.assert_true(app.api_v1_save_garment(mutation)->'error'->>'code' = 'version_conflict', 'stale device cannot overwrite');
        END LOOP;
    END LOOP;
    mutation := jsonb_set(mutation,'{base_version}',to_jsonb(current_version));
    mutation := jsonb_set(mutation,'{garment,archived}','true');
    PERFORM pg_temp.assert_true(app.api_v1_save_garment(mutation)->'data'->>'archived' = 'true', 'archive before old-client edit');
    mutation := jsonb_set(mutation,'{operation_id}',to_jsonb(gen_random_uuid()));
    mutation := jsonb_set(mutation,'{base_version}',to_jsonb(current_version + 1)) #- '{garment,archived}';
    PERFORM pg_temp.assert_true(app.api_v1_save_garment(mutation)->'data'->>'archived' = 'true', 'legacy edit preserves archive');
    mutation := jsonb_set(mutation,'{operation_id}',to_jsonb(gen_random_uuid()));
    mutation := jsonb_set(mutation,'{garment_id}','"20000000-0000-0000-0000-000000000001"');
    mutation := jsonb_set(mutation,'{base_version}','1');
    PERFORM pg_temp.assert_true(app.api_v1_save_garment(mutation)->'error'->>'code' = 'version_conflict', 'foreign status write denied');

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
