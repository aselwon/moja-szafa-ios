-- Queue payloads/results are durable, private and never returned by status RPCs.
CREATE TABLE api_private.job_payloads (
    job_id uuid PRIMARY KEY REFERENCES app.ai_jobs(id) ON DELETE CASCADE,
    input jsonb NOT NULL CHECK (jsonb_typeof(input) = 'object'),
    result jsonb
);
REVOKE ALL ON api_private.job_payloads FROM PUBLIC, anon, authenticated;

-- Trusted admission only: the feature service must check consent, ownership and
-- budget before this transaction. Clients cannot choose units or retry policy.
CREATE FUNCTION app.jobs_enqueue(owner_id uuid, operation_id uuid, job_kind text, payload jsonb,
    units integer DEFAULT 1) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
DECLARE j app.ai_jobs%ROWTYPE;
BEGIN
    IF owner_id IS NULL OR operation_id IS NULL OR units IS NULL OR units < 1
       OR jsonb_typeof(payload) IS DISTINCT FROM 'object' THEN
        RAISE EXCEPTION 'Invalid job' USING ERRCODE = '22023';
    END IF;
    PERFORM 1 FROM app.profiles WHERE user_id = owner_id AND deleted_at IS NULL FOR SHARE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Account unavailable' USING ERRCODE = '22023'; END IF;
    INSERT INTO app.ai_jobs(user_id,client_request_id,kind)
        VALUES(owner_id,operation_id,job_kind) ON CONFLICT (user_id,client_request_id) DO NOTHING
        RETURNING * INTO j;
    IF FOUND THEN
        INSERT INTO api_private.job_payloads(job_id,input) VALUES(j.id,payload);
        INSERT INTO app.usage_reservations(user_id,ai_job_id,client_request_id,units,expires_at)
            VALUES(owner_id,j.id,operation_id,units,clock_timestamp() + interval '24 hours');
    ELSE
        SELECT * INTO STRICT j FROM app.ai_jobs
            WHERE user_id = owner_id AND client_request_id = operation_id FOR UPDATE;
        IF j.kind IS DISTINCT FROM job_kind OR j.deleted_at IS NOT NULL
           OR NOT EXISTS (SELECT FROM api_private.job_payloads WHERE job_id = j.id AND input = payload)
           OR NOT EXISTS (SELECT FROM app.usage_reservations r WHERE r.ai_job_id = j.id AND r.units = jobs_enqueue.units) THEN
            RAISE EXCEPTION 'Idempotency conflict' USING ERRCODE = '22023';
        END IF;
    END IF;
    RETURN j.id;
END $$;

-- Each claim is a short transaction; no transaction spans a provider call.
-- Expired leases count as attempts. Recovery is performed by every worker poll.
CREATE FUNCTION app.jobs_claim() RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
DECLARE j app.ai_jobs%ROWTYPE; t timestamptz := clock_timestamp();
BEGIN
    FOR j IN SELECT q.* FROM app.ai_jobs q
        WHERE q.deleted_at IS NULL AND q.status IN ('queued','running')
          AND ((q.status = 'running' AND q.lease_expires_at <= t)
            OR (q.status = 'queued' AND (q.attempts >= q.max_attempts OR NOT EXISTS
                (SELECT FROM app.profiles p WHERE p.user_id = q.user_id AND p.deleted_at IS NULL))))
        ORDER BY q.available_at,q.id FOR UPDATE SKIP LOCKED LIMIT 100
    LOOP
        IF j.attempts >= j.max_attempts OR NOT EXISTS
            (SELECT FROM app.profiles WHERE user_id = j.user_id AND deleted_at IS NULL) THEN
            UPDATE app.ai_jobs SET status = 'dead_letter', lease_token = NULL, lease_expires_at = NULL,
                error_code = 'attempts_exhausted_or_account_unavailable', finished_at = t WHERE id = j.id;
            UPDATE app.usage_reservations SET status = 'released'
                WHERE ai_job_id = j.id AND status = 'reserved';
        ELSIF j.status = 'running' THEN
            UPDATE app.ai_jobs SET status = 'queued', lease_token = NULL, lease_expires_at = NULL,
                error_code = 'lease_expired', available_at = t + make_interval(secs => 5 * j.attempts)
                WHERE id = j.id;
        END IF;
    END LOOP;
    SELECT q.* INTO j FROM app.ai_jobs q
        WHERE q.status = 'queued' AND q.deleted_at IS NULL AND q.available_at <= t
          AND q.attempts < q.max_attempts
          AND EXISTS (SELECT FROM app.profiles p WHERE p.user_id = q.user_id AND p.deleted_at IS NULL)
          AND EXISTS (SELECT FROM api_private.job_payloads p WHERE p.job_id = q.id)
          AND EXISTS (SELECT FROM app.usage_reservations r WHERE r.ai_job_id = q.id AND r.status = 'reserved')
        ORDER BY q.available_at,q.id FOR UPDATE SKIP LOCKED LIMIT 1;
    IF NOT FOUND THEN RETURN NULL; END IF;
    UPDATE app.ai_jobs SET status = 'running', attempts = attempts + 1,
        lease_token = gen_random_uuid(), lease_expires_at = t + interval '60 seconds'
        WHERE id = j.id RETURNING * INTO j;
    -- Reservation expiry is bookkeeping, not authorization to release active work.
    UPDATE app.usage_reservations SET expires_at = greatest(expires_at,t + interval '24 hours') WHERE ai_job_id = j.id;
    RETURN jsonb_build_object('id',j.id,'user_id',j.user_id,'kind',j.kind,'lease_token',j.lease_token,
        'attempt',j.attempts,'input',(SELECT input FROM api_private.job_payloads WHERE job_id = j.id));
END $$;

-- Token AND expiry fence late responses, including workers resurrected after restart.
-- Result persistence, terminal state and usage settlement share one commit.
CREATE FUNCTION app.jobs_finish(job_id uuid, token uuid, outcome text, output jsonb DEFAULT NULL) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
DECLARE j app.ai_jobs%ROWTYPE; terminal boolean; t timestamptz;
BEGIN
    IF outcome IS NULL OR outcome NOT IN ('success','retry','permanent','timeout') OR
       (outcome = 'success' AND jsonb_typeof(output) IS DISTINCT FROM 'object') THEN
        RAISE EXCEPTION 'Invalid outcome' USING ERRCODE = '22023';
    END IF;
    SELECT * INTO j FROM app.ai_jobs WHERE id = job_id FOR UPDATE;
    t := clock_timestamp();
    IF NOT FOUND OR j.status <> 'running' OR j.deleted_at IS NOT NULL OR
       j.lease_token IS DISTINCT FROM token OR j.lease_expires_at <= t THEN RETURN false; END IF;
    terminal := outcome IN ('success','permanent') OR j.attempts >= j.max_attempts;
    UPDATE app.ai_jobs SET status = CASE WHEN outcome = 'success' THEN 'succeeded'
            WHEN terminal THEN 'dead_letter' ELSE 'queued' END,
        lease_token = NULL, lease_expires_at = NULL,
        available_at = t + make_interval(secs => 5 * j.attempts),
        error_code = CASE WHEN outcome = 'success' THEN NULL ELSE outcome END,
        finished_at = CASE WHEN terminal THEN t ELSE NULL END WHERE id = j.id;
    IF outcome = 'success' THEN
        UPDATE api_private.job_payloads SET result = output WHERE job_payloads.job_id = j.id;
    END IF;
    IF terminal THEN
        UPDATE app.usage_reservations SET status = CASE WHEN outcome = 'success' THEN 'settled' ELSE 'released' END
            WHERE ai_job_id = j.id AND status = 'reserved';
        IF NOT FOUND THEN
            -- Fail atomically if another subsystem has violated queue ownership
            -- of reservation transitions; never publish an unaccounted success.
            RAISE EXCEPTION 'Reservation unavailable' USING ERRCODE = '23514';
        END IF;
    END IF;
    RETURN true;
END $$;
REVOKE ALL ON FUNCTION app.jobs_enqueue(uuid,uuid,text,jsonb,integer), app.jobs_claim(),
    app.jobs_finish(uuid,uuid,text,jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION app.jobs_enqueue(uuid,uuid,text,jsonb,integer), app.jobs_claim(),
    app.jobs_finish(uuid,uuid,text,jsonb) TO service_role;

-- Rediscover work after app relaunch without any in-memory job ID or lease data.
CREATE FUNCTION app.api_v1_list_jobs(request jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
DECLARE owner_id uuid := auth.uid(); request_id uuid := gen_random_uuid();
    page_limit integer; after_id uuid; rows jsonb; next_cursor uuid;
BEGIN
    IF owner_id IS NULL THEN
        RETURN jsonb_build_object('error',jsonb_build_object('code','unauthorized','message','Sign in required','request_id',request_id));
    END IF;
    IF NOT EXISTS (SELECT FROM app.profiles WHERE user_id = owner_id AND deleted_at IS NULL) THEN
        RETURN jsonb_build_object('error',jsonb_build_object('code','account_unavailable','message','Account unavailable','request_id',request_id));
    END IF;
    IF jsonb_typeof(request) IS DISTINCT FROM 'object' OR NOT request ?& ARRAY['limit','cursor']
       OR request - ARRAY['limit','cursor'] <> '{}'::jsonb
       OR jsonb_typeof(request->'limit') IS DISTINCT FROM 'number'
       OR (request->>'limit') !~ '^[0-9]+$' THEN RAISE EXCEPTION USING ERRCODE = '22023'; END IF;
    page_limit := (request->>'limit')::integer;
    after_id := (request->>'cursor')::uuid;
    IF page_limit NOT BETWEEN 1 AND 100 THEN RAISE EXCEPTION USING ERRCODE = '22023'; END IF;
    SELECT coalesce(jsonb_agg(jsonb_build_object('id',q.id,'kind',q.kind,'status',q.status,
        'attempts',q.attempts,'error_code',q.error_code) ORDER BY q.id),'[]'::jsonb) INTO rows
        FROM (SELECT * FROM app.ai_jobs WHERE user_id = owner_id AND deleted_at IS NULL
            AND (after_id IS NULL OR id > after_id) ORDER BY id LIMIT page_limit + 1) q;
    IF jsonb_array_length(rows) > page_limit THEN
        rows := rows - page_limit; next_cursor := (rows->(page_limit - 1)->>'id')::uuid;
    END IF;
    RETURN jsonb_build_object('data',jsonb_build_object('items',rows,'next_cursor',next_cursor),'request_id',request_id);
EXCEPTION WHEN invalid_text_representation OR numeric_value_out_of_range OR invalid_parameter_value THEN
    RETURN jsonb_build_object('error',jsonb_build_object('code','validation_failed','message','Invalid pagination','request_id',request_id));
WHEN OTHERS THEN
    RETURN jsonb_build_object('error',jsonb_build_object('code','internal_error','message','Request could not be completed','request_id',request_id));
END $$;
REVOKE ALL ON FUNCTION app.api_v1_list_jobs(jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION app.api_v1_list_jobs(jsonb) TO authenticated;
