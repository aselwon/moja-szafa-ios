BEGIN;
CREATE FUNCTION pg_temp.check_deletion(ok boolean) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF ok IS DISTINCT FROM true THEN RAISE EXCEPTION 'Deletion assertion failed'; END IF; END $$;
INSERT INTO auth.users VALUES ('00000000-0000-0000-0000-000000000081'), ('00000000-0000-0000-0000-000000000082');
INSERT INTO app.profiles(id,user_id) SELECT id,id FROM auth.users WHERE id::text LIKE '%00000000008_';
INSERT INTO app.garments(user_id,name,category) VALUES
    ('00000000-0000-0000-0000-000000000081','Delete me','top'),
    ('00000000-0000-0000-0000-000000000082','Keep me','top');
DO $$ DECLARE
    a uuid := '00000000-0000-0000-0000-000000000081';
    op uuid := gen_random_uuid(); receipt jsonb; j jsonb; fence jsonb; stage text;
BEGIN
    INSERT INTO api_private.image_uploads(id,user_id,garment_id)
        SELECT gen_random_uuid(),a,id FROM app.garments WHERE user_id = a;
    receipt := app.deletion_command(jsonb_build_object('action','begin','owner',a,'operationID',op));
    PERFORM pg_temp.check_deletion(receipt->>'status' = 'queued');
    PERFORM pg_temp.check_deletion(app.deletion_command(jsonb_build_object('action','begin','owner',a,'operationID',op)) = receipt);
    PERFORM pg_temp.check_deletion(app.deletion_command(jsonb_build_object('action','receipt','owner',a,'operationID',gen_random_uuid())) = 'null');
    PERFORM pg_temp.check_deletion((SELECT deleted_at IS NOT NULL FROM app.profiles WHERE user_id = a));
    PERFORM pg_temp.check_deletion((SELECT state = 'retired' FROM api_private.image_uploads WHERE user_id = a));
    PERFORM set_config('request.jwt.claim.sub',a::text,true);
    PERFORM pg_temp.check_deletion(app.api_v1_sync_snapshot('{}')->'error'->>'code' = 'account_unavailable');
    PERFORM pg_temp.check_deletion(app.api_v1_save_garment('{}')->'error'->>'code' = 'account_unavailable');
    PERFORM pg_temp.check_deletion(app.api_v1_save_wear('{}')->'error'->>'code' = 'account_unavailable');
    j := app.deletion_command('{"action":"claim"}');
    PERFORM pg_temp.check_deletion(app.deletion_command('{"action":"claim"}') = 'null');
    fence := jsonb_build_object('id',j->>'id','token',j->>'lease_token','stage',j->>'stage');
    PERFORM pg_temp.check_deletion(app.deletion_command(fence || jsonb_build_object('action','advance','token',gen_random_uuid())) = 'false');
    UPDATE app.deletion_jobs SET lease_expires_at = clock_timestamp() - interval '1 second' WHERE id = (j->>'id')::uuid;
    PERFORM pg_temp.check_deletion(app.deletion_command(fence || '{"action":"advance"}') = 'false');
    -- Restart reclaims the same step; stale worker cannot advance it.
    j := app.deletion_command('{"action":"claim"}');
    PERFORM pg_temp.check_deletion(j->>'stage' = 'sessions');
    PERFORM pg_temp.check_deletion(app.deletion_command(fence || '{"action":"advance"}') = 'false');
    PERFORM pg_temp.check_deletion(app.deletion_command(jsonb_build_object('action','retry','id',j->>'id','token',j->>'lease_token')) = 'true');
    UPDATE app.deletion_jobs SET available_at = clock_timestamp() WHERE user_id = a;
    FOREACH stage IN ARRAY ARRAY['sessions','apple','images','identity','purge'] LOOP
        j := app.deletion_command('{"action":"claim"}');
        PERFORM pg_temp.check_deletion(j->>'stage' = stage);
        PERFORM pg_temp.check_deletion(app.deletion_command(jsonb_build_object('action','advance','id',j->>'id','token',j->>'lease_token','stage',stage)) = 'true');
    END LOOP;
    PERFORM pg_temp.check_deletion(NOT EXISTS (SELECT FROM app.profiles WHERE user_id = a));
    PERFORM pg_temp.check_deletion(NOT EXISTS (SELECT FROM app.garments WHERE user_id = a));
    PERFORM pg_temp.check_deletion((SELECT count(*) = 1 FROM app.garments WHERE name = 'Keep me'));
    PERFORM pg_temp.check_deletion((SELECT status = 'succeeded' AND stage = 'done' FROM app.deletion_jobs WHERE user_id = a));
    -- Ledgers intentionally survive to suppress restores and late image writers.
    PERFORM pg_temp.check_deletion((SELECT count(*) = 1 FROM api_private.image_uploads WHERE user_id = a));
    BEGIN
        INSERT INTO app.profiles(id,user_id) VALUES(a,a);
        RAISE EXCEPTION 'Deleted account was reprovisioned';
    EXCEPTION WHEN check_violation THEN NULL; END;
END $$;
SELECT pg_temp.check_deletion(NOT has_function_privilege('authenticated','app.deletion_command(jsonb)','EXECUTE'));
SELECT pg_temp.check_deletion(NOT has_function_privilege('anon','app.deletion_command(jsonb)','EXECUTE'));
-- Old JWT sees no data, while another account retains its data.
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000081',true);
SELECT pg_temp.check_deletion((SELECT count(*) = 0 FROM app.garments));
SELECT set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000082',true);
SELECT pg_temp.check_deletion((SELECT count(*) = 1 FROM app.garments));
RESET ROLE;
ROLLBACK;
