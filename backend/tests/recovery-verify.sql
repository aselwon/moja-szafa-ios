DO $$ BEGIN
    IF (SELECT count(*) FROM auth.users) <> 2
       OR EXISTS (SELECT FROM auth.users WHERE id = '10000000-0000-0000-0000-000000000001')
       OR (SELECT count(*) FROM app.profiles) <> 2
       OR (SELECT count(*) FROM app.garments WHERE deleted_at IS NULL) <> 1
       OR (SELECT count(*) FROM app.garments WHERE deleted_at IS NOT NULL) <> 2
       OR NOT EXISTS (SELECT FROM app.garments
           WHERE user_id = '10000000-0000-0000-0000-000000000003' AND price_grosz = 80000)
       OR (SELECT count(*) FROM app.garment_images) <> 2
       OR (SELECT count(*) FROM api_private.image_uploads WHERE state = 'retired' AND fence IS NULL) <> 2
       OR (SELECT count(*) FROM api_private.image_uploads WHERE state = 'ready') <> 1 THEN
        RAISE EXCEPTION 'Recovery deletion replay or survivor integrity failed';
    END IF;
END $$;

-- Test a new create intent, not a previously cached response: both the restored
-- garment and a post-backup draft must reject stale offline creation attempts.
DO $$
DECLARE
    target uuid;
    outcome jsonb;
    previous_subject text := current_setting('request.jwt.claim.sub', true);
BEGIN
    PERFORM set_config('request.jwt.claim.sub', '10000000-0000-0000-0000-000000000002', true);
    FOREACH target IN ARRAY ARRAY[
        '20000000-0000-0000-0000-000000000002'::uuid,
        '20000000-0000-0000-0000-000000000004'::uuid
    ] LOOP
        outcome := app.api_v1_save_garment(jsonb_build_object(
            'operation_id',gen_random_uuid(), 'garment_id',target,'base_version',NULL,
            'garment',jsonb_build_object(
                'name','Stale offline create','category','top',
                'price_grosz',9000,'availability','available')));
        IF outcome->'error'->>'code' IS DISTINCT FROM 'version_conflict' OR EXISTS (
            SELECT FROM app.garments WHERE id=target AND deleted_at IS NULL
        ) THEN RAISE EXCEPTION 'Recovery allowed a deleted garment to be recreated'; END IF;
    END LOOP;
    IF EXISTS (SELECT FROM app.garments
        WHERE user_id='10000000-0000-0000-0000-000000000002'
          AND (deleted_at IS NULL OR name <> 'Deleted' OR price_grosz IS NOT NULL)) THEN
        RAISE EXCEPTION 'Recovery retained private garment metadata';
    END IF;
    PERFORM set_config('request.jwt.claim.sub', coalesce(previous_subject, ''), true);
END $$;
