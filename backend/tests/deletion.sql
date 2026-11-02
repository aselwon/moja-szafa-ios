BEGIN;
INSERT INTO auth.users(id) VALUES('17000000-0000-0000-0000-000000000001'),('17000000-0000-0000-0000-000000000002');
INSERT INTO app.profiles(id,user_id) SELECT id,id FROM auth.users WHERE id::text LIKE '17000000%';
INSERT INTO app.garments(user_id,name,category) VALUES('17000000-0000-0000-0000-000000000001','delete me','top'),('17000000-0000-0000-0000-000000000002','keep me','top');
INSERT INTO api_private.image_uploads(id,user_id,garment_id)
SELECT gen_random_uuid(),user_id,id FROM app.garments WHERE name = 'delete me';
SELECT app.deletion_enqueue('17000000-0000-0000-0000-000000000001',gen_random_uuid());
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub','17000000-0000-0000-0000-000000000001',true);
DO $$ BEGIN
    IF EXISTS (SELECT FROM app.garments) THEN RAISE EXCEPTION 'old JWT can still read wardrobe'; END IF;
END $$;
RESET ROLE;
DO $$ DECLARE job uuid; claim jsonb; BEGIN
    IF has_function_privilege('authenticated','app.deletion_enqueue(uuid,uuid)','EXECUTE') THEN
        RAISE EXCEPTION 'client can bypass reauthorization';
    END IF;
    job := app.deletion_enqueue('17000000-0000-0000-0000-000000000001',gen_random_uuid());
    IF job <> app.deletion_enqueue('17000000-0000-0000-0000-000000000001',gen_random_uuid()) THEN
        RAISE EXCEPTION 'duplicate deletion';
    END IF;
    IF EXISTS (SELECT FROM api_private.image_uploads WHERE user_id = '17000000-0000-0000-0000-000000000001' AND state <> 'retired') THEN
        RAISE EXCEPTION 'image publication not fenced';
    END IF;
    claim := app.deletion_claim();
    IF app.deletion_finish(job,gen_random_uuid(),true) THEN RAISE EXCEPTION 'stale worker accepted'; END IF;
    IF NOT app.deletion_finish(job,(claim->>'token')::uuid,false) THEN RAISE EXCEPTION 'retry failed'; END IF;
    UPDATE app.deletion_jobs SET available_at = now() - interval '1 second' WHERE id = job;
    claim := app.deletion_claim();
    IF NOT app.deletion_finish(job,(claim->>'token')::uuid,true) THEN RAISE EXCEPTION 'cleanup failed'; END IF;
    IF EXISTS (SELECT FROM app.garments WHERE user_id = '17000000-0000-0000-0000-000000000001') THEN
        RAISE EXCEPTION 'domain data remains';
    END IF;
    IF NOT EXISTS (SELECT FROM app.garments WHERE name = 'keep me') THEN RAISE EXCEPTION 'cross-owner deletion'; END IF;
    IF job <> app.deletion_enqueue('17000000-0000-0000-0000-000000000001',gen_random_uuid()) THEN
        RAISE EXCEPTION 'replay after purge failed';
    END IF;
END $$;
ROLLBACK;
