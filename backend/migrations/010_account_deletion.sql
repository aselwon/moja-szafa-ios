-- Queue survives auth.users deletion. No credentials or user content in this ledger.
CREATE UNIQUE INDEX deletion_one_per_owner ON app.deletion_jobs(user_id);
ALTER TABLE app.deletion_jobs ADD COLUMN available_at timestamptz NOT NULL DEFAULT now();
-- A stale JWT must not read rows after the deletion tombstone commits.
DO $$ DECLARE t record; BEGIN
    FOR t IN SELECT tablename FROM pg_tables WHERE schemaname = 'app' AND tablename <> 'profiles' LOOP
        EXECUTE format('CREATE POLICY account_live ON app.%I AS RESTRICTIVE FOR ALL TO authenticated USING (EXISTS (SELECT FROM app.profiles WHERE user_id = auth.uid() AND deleted_at IS NULL))', t.tablename);
    END LOOP;
END $$;
CREATE POLICY profile_live ON app.profiles AS RESTRICTIVE FOR ALL TO authenticated USING (deleted_at IS NULL);

CREATE FUNCTION app.deletion_command(request jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
DECLARE
    action text := request->>'action';
    owner_id uuid := (request->>'owner')::uuid;
    job app.deletion_jobs%ROWTYPE;
BEGIN
    IF action = 'request' THEN
        -- Caller MUST verify a fresh, account-bound deletion challenge first.
        PERFORM 1 FROM app.profiles WHERE user_id = owner_id FOR UPDATE;
        SELECT * INTO job FROM app.deletion_jobs WHERE user_id = owner_id;
        IF FOUND THEN RETURN jsonb_build_object('id',job.id,'status','accepted'); END IF;
        IF NOT EXISTS (SELECT FROM app.profiles WHERE user_id = owner_id AND deleted_at IS NULL)
           OR request->>'id' IS NULL THEN RETURN 'null'::jsonb; END IF;
        INSERT INTO app.deletion_jobs(user_id,client_request_id) VALUES(owner_id,(request->>'id')::uuid) RETURNING * INTO job;
        UPDATE app.profiles SET deleted_at = clock_timestamp() WHERE user_id = owner_id;
        DELETE FROM api_private.data_exports WHERE user_id = owner_id;
        UPDATE api_private.image_uploads SET state = 'retired', fence = NULL, next_cleanup_at = clock_timestamp() WHERE user_id = owner_id;
        RETURN jsonb_build_object('id',job.id,'status','accepted');
    ELSIF action = 'claim' THEN
        UPDATE app.deletion_jobs SET status = 'dead_letter', lease_token = NULL, lease_expires_at = NULL,
            error_code = 'attempts_exhausted'
        WHERE attempts >= 8 AND (status = 'queued' OR (status = 'running' AND lease_expires_at <= clock_timestamp()));
        SELECT * INTO job FROM app.deletion_jobs WHERE attempts < 8 AND
            ((status = 'queued' AND available_at <= clock_timestamp()) OR
             (status = 'running' AND lease_expires_at <= clock_timestamp()))
            ORDER BY created_at FOR UPDATE SKIP LOCKED LIMIT 1;
        IF NOT FOUND THEN RETURN 'null'::jsonb; END IF;
        UPDATE app.deletion_jobs SET status = 'running', attempts = attempts + 1,
            lease_token = gen_random_uuid(), lease_expires_at = clock_timestamp() + interval '5 minutes'
            WHERE id = job.id RETURNING * INTO job;
        RETURN jsonb_build_object('id',job.id,'owner',job.user_id,'fence',job.lease_token);
    END IF;
    SELECT * INTO job FROM app.deletion_jobs WHERE id = (request->>'id')::uuid FOR UPDATE;
    IF NOT FOUND OR job.status <> 'running' OR job.lease_token IS DISTINCT FROM (request->>'fence')::uuid
        OR job.lease_expires_at <= clock_timestamp() THEN RETURN 'false'::jsonb; END IF;
    IF action = 'finish' THEN
        -- Auth deletion cascades through all owned tables. External revocations and
        -- storage erasure must have succeeded before this transaction is called.
        DELETE FROM app.operator_audit WHERE user_id = job.user_id;
        DELETE FROM auth.users WHERE id = job.user_id;
        DELETE FROM app.profiles WHERE user_id = job.user_id;
        UPDATE app.deletion_jobs SET status = 'succeeded', lease_token = NULL, lease_expires_at = NULL,
            finished_at = clock_timestamp(), error_code = NULL WHERE id = job.id;
    ELSIF action = 'retry' THEN
        UPDATE app.deletion_jobs SET status = 'queued', lease_token = NULL, lease_expires_at = NULL,
            available_at = clock_timestamp() + interval '1 minute' * least(60, attempts * attempts),
            error_code = 'cleanup_unavailable' WHERE id = job.id;
    ELSE RETURN 'false'::jsonb;
    END IF;
    RETURN 'true'::jsonb;
END $$;
REVOKE ALL ON FUNCTION app.deletion_command(jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION app.deletion_command(jsonb) TO service_role;
