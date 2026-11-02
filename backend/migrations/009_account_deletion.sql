-- Server-only entry point: gateway must verify fresh identity proof for this
-- exact subject before calling. Never expose this function through public RPC.
CREATE UNIQUE INDEX deletion_jobs_account ON app.deletion_jobs(user_id);
CREATE FUNCTION app.deletion_begin(owner_id uuid, operation_id uuid) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
DECLARE job_id uuid;
BEGIN
    IF owner_id IS NULL OR operation_id IS NULL THEN RAISE EXCEPTION 'invalid_request'; END IF;
    PERFORM pg_advisory_xact_lock(hashtextextended(owner_id::text, 17));
    -- Serialize with all existing writes/AI dispatch/image publication.
    PERFORM 1 FROM app.profiles WHERE user_id = owner_id FOR UPDATE;
    SELECT id INTO job_id FROM app.deletion_jobs WHERE user_id = owner_id;
    IF job_id IS NOT NULL THEN RETURN job_id; END IF;
    IF NOT EXISTS (SELECT FROM app.profiles WHERE user_id = owner_id) THEN
        RAISE EXCEPTION 'account_unavailable';
    END IF;
    INSERT INTO app.deletion_jobs(user_id,client_request_id) VALUES(owner_id,operation_id) RETURNING id INTO job_id;
    UPDATE api_private.image_uploads SET state = 'retired', fence = NULL, next_cleanup_at = clock_timestamp()
        WHERE user_id = owner_id;
    -- Cascades include history, preferences, AI payloads and mutation responses.
    DELETE FROM app.profiles WHERE user_id = owner_id;
    DELETE FROM app.operator_audit WHERE user_id = owner_id;
    RETURN job_id;
END $$;

CREATE FUNCTION app.deletion_claim() RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
DECLARE job app.deletion_jobs%ROWTYPE;
BEGIN
    SELECT * INTO job FROM app.deletion_jobs
    WHERE status = 'queued' OR (status = 'running' AND lease_expires_at < clock_timestamp())
    ORDER BY created_at FOR UPDATE SKIP LOCKED LIMIT 1;
    IF NOT FOUND THEN RETURN NULL; END IF;
    IF job.attempts >= 8 THEN
        UPDATE app.deletion_jobs SET status = 'dead_letter', lease_token = NULL, lease_expires_at = NULL,
            error_code = 'retry_exhausted' WHERE id = job.id;
        RETURN NULL;
    END IF;
    UPDATE app.deletion_jobs SET status = 'running', attempts = attempts + 1,
        lease_token = gen_random_uuid(), lease_expires_at = clock_timestamp() + interval '5 minutes'
        WHERE id = job.id RETURNING * INTO job;
    RETURN jsonb_build_object('id',job.id,'owner',job.user_id,'lease',job.lease_token,
        'images',(SELECT coalesce(jsonb_agg(id),'[]'::jsonb) FROM api_private.image_uploads WHERE user_id = job.user_id));
END $$;

CREATE FUNCTION app.deletion_finish(job_id uuid, token uuid) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
BEGIN
    UPDATE app.deletion_jobs SET status = 'succeeded', finished_at = clock_timestamp(),
        lease_token = NULL, lease_expires_at = NULL, error_code = NULL
    WHERE id = job_id AND status = 'running' AND lease_token = token AND lease_expires_at > clock_timestamp();
    RETURN FOUND;
END $$;
REVOKE ALL ON FUNCTION app.deletion_begin(uuid,uuid), app.deletion_claim(), app.deletion_finish(uuid,uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION app.deletion_begin(uuid,uuid), app.deletion_claim(), app.deletion_finish(uuid,uuid) TO service_role;

-- A stale login/bootstrap or restored outbox cannot resurrect the same subject.
CREATE FUNCTION app.prevent_deleted_profile() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
BEGIN
    PERFORM pg_advisory_xact_lock(hashtextextended(NEW.user_id::text, 17));
    IF EXISTS (SELECT FROM app.deletion_jobs WHERE user_id = NEW.user_id) THEN
        RAISE EXCEPTION 'account_unavailable';
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER prevent_deleted_profile BEFORE INSERT ON app.profiles
FOR EACH ROW EXECUTE FUNCTION app.prevent_deleted_profile();
REVOKE ALL ON FUNCTION app.prevent_deleted_profile() FROM PUBLIC, anon, authenticated;
