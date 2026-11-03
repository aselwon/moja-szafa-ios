-- Server-only entry point. The gateway must verify fresh authentication and
-- derive owner from that proof; never expose this RPC through a user JWT.
ALTER TABLE app.deletion_jobs ADD COLUMN stage text NOT NULL DEFAULT 'sessions'
    CHECK (stage IN ('sessions','apple','images','identity','purge','done'));
ALTER TABLE app.deletion_jobs ADD COLUMN available_at timestamptz NOT NULL DEFAULT now();
CREATE INDEX deletion_account_lookup ON app.deletion_jobs(user_id, created_at, id);

CREATE FUNCTION app.deletion_command(request jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
DECLARE
    action text := request->>'action';
    owner_id uuid := (request->>'owner')::uuid;
    j app.deletion_jobs%ROWTYPE;
    t timestamptz := clock_timestamp();
BEGIN
    IF action = 'receipt' THEN
        SELECT * INTO j FROM app.deletion_jobs WHERE user_id = owner_id
            AND client_request_id = (request->>'operationID')::uuid;
        IF NOT FOUND THEN RETURN 'null'::jsonb; END IF;
        RETURN jsonb_build_object('jobID',j.id,'status',j.status);
    ELSIF action = 'begin' THEN
        IF owner_id IS NULL OR (request->>'operationID')::uuid IS NULL THEN
            RAISE EXCEPTION 'invalid deletion request';
        END IF;
        -- Serialize repeated requests even after the profile has been purged.
        -- Do not impose uniqueness retroactively on pre-existing job history.
        PERFORM pg_advisory_xact_lock(hashtextextended(owner_id::text, 17));
        -- Serialize with all existing mutation and image publication locks.
        PERFORM 1 FROM app.profiles WHERE user_id = owner_id FOR UPDATE;
        IF NOT FOUND AND NOT EXISTS (SELECT FROM app.deletion_jobs WHERE user_id = owner_id) THEN
            RAISE EXCEPTION 'account unavailable';
        END IF;
        INSERT INTO app.deletion_jobs(user_id, client_request_id)
            SELECT owner_id,(request->>'operationID')::uuid
            WHERE NOT EXISTS (SELECT FROM app.deletion_jobs WHERE user_id = owner_id);
        UPDATE app.profiles SET deleted_at = t WHERE user_id = owner_id AND deleted_at IS NULL;
        UPDATE api_private.image_uploads SET state = 'retired', fence = NULL, next_cleanup_at = t
            WHERE user_id = owner_id;
        SELECT * INTO j FROM app.deletion_jobs WHERE user_id = owner_id ORDER BY created_at,id LIMIT 1;
        RETURN jsonb_build_object('jobID',j.id,'status',j.status);
    ELSIF action = 'claim' THEN
        UPDATE app.deletion_jobs SET status = 'dead_letter', lease_token = NULL, lease_expires_at = NULL,
            error_code = 'retry_exhausted' WHERE status = 'running' AND lease_expires_at <= t AND attempts >= 8;
        SELECT * INTO j FROM app.deletion_jobs
            WHERE (status = 'queued' AND available_at <= t OR status = 'running' AND lease_expires_at <= t)
              AND attempts < 8 ORDER BY created_at FOR UPDATE SKIP LOCKED LIMIT 1;
        IF NOT FOUND THEN RETURN 'null'::jsonb; END IF;
        UPDATE app.deletion_jobs SET status = 'running', attempts = attempts + 1,
            lease_token = gen_random_uuid(), lease_expires_at = t + interval '2 minutes'
            WHERE id = j.id RETURNING * INTO j;
        RETURN jsonb_build_object('id',j.id,'owner',j.user_id,'stage',j.stage,'lease_token',j.lease_token);
    END IF;
    SELECT * INTO j FROM app.deletion_jobs WHERE id = (request->>'id')::uuid FOR UPDATE;
    IF NOT FOUND OR j.status <> 'running' OR j.lease_expires_at <= t
        OR j.lease_token IS DISTINCT FROM (request->>'token')::uuid THEN RETURN 'false'::jsonb; END IF;
    IF action = 'images' THEN
        RETURN (SELECT coalesce(jsonb_agg(id), '[]'::jsonb) FROM api_private.image_uploads WHERE user_id = j.user_id);
    ELSIF action = 'retry' THEN
        UPDATE app.deletion_jobs SET status = CASE WHEN attempts >= 8 THEN 'dead_letter' ELSE 'queued' END,
            lease_token = NULL, lease_expires_at = NULL, error_code = 'cleanup_unavailable',
            available_at = t + make_interval(secs => 30 * attempts) WHERE id = j.id;
    ELSIF action = 'advance' AND request->>'stage' = j.stage THEN
        IF j.stage = 'purge' THEN
            -- Cascades cover wardrobe, history, plans, preferences, consent,
            -- subscriptions, support, AI payloads and mutation replay bodies.
            DELETE FROM app.profiles WHERE user_id = j.user_id;
            DELETE FROM app.operator_audit WHERE user_id = j.user_id;
            -- Deletion/image ledgers deliberately survive for restore suppression
            -- and late image writes; they contain IDs only, no user content.
        END IF;
        UPDATE app.deletion_jobs SET stage = CASE j.stage
            WHEN 'sessions' THEN 'apple' WHEN 'apple' THEN 'images' WHEN 'images' THEN 'identity'
            WHEN 'identity' THEN 'purge' WHEN 'purge' THEN 'done' END,
            status = CASE WHEN j.stage = 'purge' THEN 'succeeded' ELSE 'queued' END,
            attempts = 0, lease_token = NULL, lease_expires_at = NULL, available_at = t,
            error_code = NULL, finished_at = CASE WHEN j.stage = 'purge' THEN t ELSE NULL END
            WHERE id = j.id;
    ELSE RETURN 'false'::jsonb;
    END IF;
    RETURN 'true'::jsonb;
END $$;
REVOKE ALL ON FUNCTION app.deletion_command(jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION app.deletion_command(jsonb) TO service_role;

-- Even an unexpired JWT cannot read an account once deletion was accepted.
-- The durable ledger also suppresses restored records until restore replay runs.
CREATE FUNCTION app.account_not_deleting(owner_id uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog AS $$
    SELECT NOT EXISTS (SELECT FROM app.deletion_jobs WHERE user_id = owner_id)
$$;
REVOKE ALL ON FUNCTION app.account_not_deleting(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION app.account_not_deleting(uuid) TO authenticated;
DO $$ DECLARE relation text; BEGIN
    FOR relation IN SELECT tablename FROM pg_tables WHERE schemaname = 'app'
        AND tablename NOT IN ('deletion_jobs','operator_audit') LOOP
        EXECUTE format('CREATE POLICY account_deletion_fence ON app.%I AS RESTRICTIVE FOR ALL TO authenticated USING (app.account_not_deleting(user_id)) WITH CHECK (app.account_not_deleting(user_id))', relation);
    END LOOP;
END $$;

-- A restored/deleted identity must never provision the same profile again.
CREATE FUNCTION app.prevent_deleted_profile() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
BEGIN
    IF EXISTS (SELECT FROM app.deletion_jobs WHERE user_id = NEW.user_id) THEN
        RAISE EXCEPTION 'account unavailable' USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER prevent_deleted_profile BEFORE INSERT ON app.profiles
    FOR EACH ROW EXECUTE FUNCTION app.prevent_deleted_profile();
