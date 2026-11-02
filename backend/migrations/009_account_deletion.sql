-- Trusted gateway only: fresh, account-bound reauthorization is verified before
-- calling enqueue. Never expose these functions as authenticated-user RPCs.
CREATE UNIQUE INDEX deletion_jobs_owner ON app.deletion_jobs(user_id);
ALTER TABLE app.deletion_jobs ADD COLUMN available_at timestamptz NOT NULL DEFAULT now();

CREATE FUNCTION app.deletion_enqueue(owner_id uuid, operation_id uuid) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
DECLARE result uuid;
BEGIN
    IF owner_id IS NULL OR operation_id IS NULL THEN RAISE EXCEPTION 'invalid_request'; END IF;
    -- Same lock as mutations, image publication and consent dispatch.
    PERFORM 1 FROM app.profiles WHERE user_id = owner_id FOR UPDATE;
    SELECT id INTO result FROM app.deletion_jobs WHERE user_id = owner_id;
    IF FOUND THEN RETURN result; END IF;
    IF NOT EXISTS (SELECT FROM app.profiles WHERE user_id = owner_id AND deleted_at IS NULL) THEN
        RAISE EXCEPTION 'account_unavailable';
    END IF;
    INSERT INTO app.deletion_jobs(user_id, client_request_id) VALUES(owner_id, operation_id) RETURNING id INTO result;
    UPDATE app.profiles SET deleted_at = clock_timestamp() WHERE user_id = owner_id;
    UPDATE api_private.image_uploads SET state = 'retired', fence = NULL, next_cleanup_at = clock_timestamp()
        WHERE user_id = owner_id;
    RETURN result;
END $$;

-- RLS also fences direct reads with an access JWT issued before deletion.
DO $$ DECLARE t text; BEGIN
    FOR t IN SELECT tablename FROM pg_tables WHERE schemaname = 'app' AND tablename <> 'profiles' LOOP
        EXECUTE format('CREATE POLICY account_active ON app.%I AS RESTRICTIVE FOR SELECT TO authenticated USING (EXISTS (SELECT FROM app.profiles p WHERE p.user_id = %I.user_id AND p.deleted_at IS NULL))', t, t);
    END LOOP;
END $$;

CREATE FUNCTION app.deletion_claim() RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
DECLARE j app.deletion_jobs%ROWTYPE;
BEGIN
    SELECT * INTO j FROM app.deletion_jobs
    WHERE (status = 'queued' AND available_at <= clock_timestamp())
       OR (status = 'running' AND lease_expires_at <= clock_timestamp())
    ORDER BY available_at, id FOR UPDATE SKIP LOCKED LIMIT 1;
    IF NOT FOUND THEN RETURN NULL; END IF;
    IF j.attempts >= 10 THEN
        UPDATE app.deletion_jobs SET status = 'dead_letter', lease_token = NULL, lease_expires_at = NULL,
            error_code = 'cleanup_attempts_exhausted' WHERE id = j.id;
        RETURN NULL;
    END IF;
    UPDATE app.deletion_jobs SET status = 'running', attempts = attempts + 1,
        lease_token = gen_random_uuid(), lease_expires_at = clock_timestamp() + interval '5 minutes'
        WHERE id = j.id RETURNING * INTO j;
    RETURN jsonb_build_object('id', j.id, 'owner', j.user_id, 'token', j.lease_token);
END $$;

CREATE FUNCTION app.deletion_finish(job_id uuid, token uuid, succeeded boolean) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
DECLARE j app.deletion_jobs%ROWTYPE;
BEGIN
    SELECT * INTO j FROM app.deletion_jobs WHERE id = job_id FOR UPDATE;
    IF NOT FOUND OR j.status <> 'running' OR j.lease_token IS DISTINCT FROM token
       OR j.lease_expires_at <= clock_timestamp() THEN RETURN false; END IF;
    IF succeeded THEN
        -- Auth identity is removed by the auth adapter only AFTER Apple revoke.
        -- Cascades remove all profile-owned domain records; private ledgers remain
        -- as deletion fences for delayed writes and backup restoration.
        DELETE FROM app.profiles WHERE user_id = j.user_id;
        DELETE FROM app.operator_audit WHERE user_id = j.user_id;
    END IF;
    UPDATE app.deletion_jobs SET status = CASE WHEN succeeded THEN 'succeeded' ELSE 'queued' END,
        lease_token = NULL, lease_expires_at = NULL,
        available_at = clock_timestamp() + interval '5 minutes',
        finished_at = CASE WHEN succeeded THEN clock_timestamp() ELSE NULL END,
        error_code = CASE WHEN succeeded THEN NULL ELSE 'cleanup_retry' END WHERE id = job_id;
    RETURN true;
END $$;
REVOKE ALL ON FUNCTION app.deletion_enqueue(uuid,uuid), app.deletion_claim(), app.deletion_finish(uuid,uuid,boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION app.deletion_enqueue(uuid,uuid), app.deletion_claim(), app.deletion_finish(uuid,uuid,boolean) TO service_role;
