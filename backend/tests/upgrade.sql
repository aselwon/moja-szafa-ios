DO $$ BEGIN
    IF NOT EXISTS (SELECT FROM app.garments WHERE name='Upgrade fixture' AND price_grosz=80000 AND version=1)
       OR NOT EXISTS (SELECT FROM app.wear_events WHERE worn_on='2020-01-01' AND timezone='Europe/Warsaw')
       OR (SELECT count(*) FROM app.wear_event_items) <> 1
       OR (SELECT max(version) FROM app.schema_migrations) <> 2 THEN
        RAISE EXCEPTION 'v1 data lost or modified during upgrade';
    END IF;
END $$;
-- Clean only this fixture before the common contract tests.
DELETE FROM auth.users WHERE id='00000000-0000-0000-0000-000000000001';
