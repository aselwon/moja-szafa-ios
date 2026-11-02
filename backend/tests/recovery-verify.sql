DO $$ BEGIN
    IF (SELECT count(*) FROM auth.users) <> 2
       OR EXISTS (SELECT FROM auth.users WHERE id = '10000000-0000-0000-0000-000000000001')
       OR (SELECT count(*) FROM app.profiles) <> 2
       OR (SELECT count(*) FROM app.garments) <> 1
       OR NOT EXISTS (SELECT FROM app.garments
           WHERE user_id = '10000000-0000-0000-0000-000000000003' AND price_grosz = 80000)
       OR (SELECT count(*) FROM app.garment_images) <> 2
       OR (SELECT count(*) FROM api_private.image_uploads WHERE state = 'retired' AND fence IS NULL) <> 2
       OR (SELECT count(*) FROM api_private.image_uploads WHERE state = 'ready') <> 1 THEN
        RAISE EXCEPTION 'Recovery deletion replay or survivor integrity failed';
    END IF;
END $$;
