BEGIN;
CREATE FUNCTION pg_temp.assert_true(ok boolean, message text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF ok IS DISTINCT FROM true THEN RAISE EXCEPTION 'Assertion failed: %', message; END IF; END $$;
INSERT INTO auth.users VALUES ('00000000-0000-0000-0000-000000000017');
INSERT INTO app.profiles(id,user_id) VALUES ('00000000-0000-0000-0000-000000000017','00000000-0000-0000-0000-000000000017');
INSERT INTO app.garments(user_id,name,category) VALUES ('00000000-0000-0000-0000-000000000017','Delete me','top');
DO $$
DECLARE owner_id uuid := '00000000-0000-0000-0000-000000000017'; job uuid; claim jsonb;
BEGIN
    job := app.deletion_begin(owner_id,gen_random_uuid());
    PERFORM pg_temp.assert_true(app.deletion_begin(owner_id,gen_random_uuid()) = job,'one job per subject even after response loss');
    PERFORM pg_temp.assert_true(NOT EXISTS (SELECT FROM app.profiles WHERE user_id = owner_id),'profile removed');
    PERFORM pg_temp.assert_true(NOT EXISTS (SELECT FROM app.garments WHERE user_id = owner_id),'data cascaded');
    PERFORM pg_temp.assert_true(EXISTS (SELECT FROM auth.users WHERE id = owner_id),'identity retained until external revocation');
    claim := app.deletion_claim();
    PERFORM pg_temp.assert_true(NOT app.deletion_finish(job,gen_random_uuid()),'stale worker fenced');
    PERFORM pg_temp.assert_true(app.deletion_finish(job,(claim->>'lease')::uuid),'current worker completes');
    PERFORM pg_temp.assert_true(app.deletion_claim() IS NULL,'completed job not retried');
    BEGIN
        INSERT INTO app.profiles(id,user_id) VALUES(owner_id,owner_id);
        RAISE EXCEPTION 'resurrection was accepted';
    EXCEPTION WHEN raise_exception THEN
        IF SQLERRM <> 'account_unavailable' THEN RAISE; END IF;
    END;
    -- Expired leases retry with a new fence and eventually stop for intervention.
    UPDATE app.deletion_jobs SET status = 'queued', finished_at = NULL WHERE id = job;
    claim := app.deletion_claim();
    UPDATE app.deletion_jobs SET lease_expires_at = clock_timestamp() - interval '1 second' WHERE id = job;
    PERFORM app.deletion_claim();
    PERFORM pg_temp.assert_true(NOT app.deletion_finish(job,(claim->>'lease')::uuid),'expired worker cannot finish newer lease');
    UPDATE app.deletion_jobs SET attempts = 8, lease_expires_at = clock_timestamp() - interval '1 second' WHERE id = job;
    PERFORM app.deletion_claim();
    PERFORM pg_temp.assert_true((SELECT status = 'dead_letter' FROM app.deletion_jobs WHERE id = job),'bounded retries');
    PERFORM pg_temp.assert_true(NOT has_function_privilege('authenticated','app.deletion_begin(uuid,uuid)','EXECUTE'),'client cannot bypass reauth');
END $$;
ROLLBACK;
