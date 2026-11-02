-- No invented provider: deployment must install an approved disclosure before AI can run.
CREATE TABLE api_private.ai_disclosure (
    singleton boolean PRIMARY KEY DEFAULT true CHECK (singleton),
    policy_version text NOT NULL CHECK (length(btrim(policy_version)) > 0),
    recipient text NOT NULL CHECK (length(btrim(recipient)) > 0),
    data_description text NOT NULL CHECK (length(btrim(data_description)) > 0),
    purpose_description text NOT NULL CHECK (length(btrim(purpose_description)) > 0)
);
REVOKE ALL ON api_private.ai_disclosure FROM PUBLIC, anon, authenticated;
ALTER TABLE app.consent_events ADD COLUMN evidence_order bigint GENERATED ALWAYS AS IDENTITY;
ALTER TABLE app.consent_events ADD COLUMN disclosure jsonb;
ALTER TABLE app.ai_jobs ADD COLUMN consent_event_id uuid REFERENCES app.consent_events(id);

CREATE FUNCTION api_private.ai_consent(owner_id uuid) RETURNS uuid
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog AS $$
    SELECT e.id FROM (SELECT * FROM app.consent_events WHERE user_id = owner_id AND purpose = 'ai'
        ORDER BY evidence_order DESC LIMIT 1) e
    JOIN api_private.ai_disclosure d ON e.policy_version = d.policy_version AND e.recipient = d.recipient
        AND e.disclosure = to_jsonb(d) - 'singleton'
    WHERE e.granted AND e.deleted_at IS NULL
$$;
REVOKE ALL ON FUNCTION api_private.ai_consent(uuid) FROM PUBLIC, anon, authenticated;

CREATE FUNCTION app.api_v1_ai_consent(request jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
DECLARE owner_id uuid := auth.uid(); rid uuid := gen_random_uuid(); d jsonb;
    e app.consent_events%ROWTYPE; op uuid; choice boolean;
BEGIN
    IF owner_id IS NULL THEN
        RETURN jsonb_build_object('error',jsonb_build_object('code','unauthorized','message','Sign in required','request_id',rid));
    END IF;
    PERFORM 1 FROM app.profiles WHERE user_id = owner_id AND deleted_at IS NULL FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Account unavailable' USING ERRCODE = '22023'; END IF;
    SELECT to_jsonb(p) - 'singleton' INTO d FROM api_private.ai_disclosure p;
    IF request <> '{}'::jsonb THEN
        IF jsonb_typeof(request) IS DISTINCT FROM 'object'
           OR NOT request ?& ARRAY['operation_id','granted','disclosure']
           OR request - ARRAY['operation_id','granted','disclosure'] <> '{}'::jsonb
           OR jsonb_typeof(request->'granted') IS DISTINCT FROM 'boolean' THEN
            RAISE EXCEPTION 'Invalid choice' USING ERRCODE = '22023';
        END IF;
        op := (request->>'operation_id')::uuid;
        choice := (request->>'granted')::boolean;
        SELECT * INTO e FROM app.consent_events WHERE user_id = owner_id AND client_request_id = op;
        IF FOUND THEN
            IF e.granted <> choice OR e.purpose <> 'ai' OR e.disclosure IS DISTINCT FROM nullif(request->'disclosure','null'::jsonb) THEN
                RAISE EXCEPTION 'Idempotency conflict' USING ERRCODE = '22023';
            END IF;
        ELSE
            IF choice AND (d IS NULL OR request->'disclosure' IS DISTINCT FROM d) THEN
                RAISE EXCEPTION 'Disclosure changed' USING ERRCODE = '22023';
            END IF;
            INSERT INTO app.consent_events(user_id,purpose,policy_version,recipient,granted,client_request_id,disclosure)
            VALUES(owner_id,'ai',coalesce(d->>'policy_version','unconfigured'),coalesce(d->>'recipient','unconfigured'),choice,op,
                nullif(request->'disclosure','null'::jsonb));
            IF NOT choice THEN
                UPDATE app.ai_jobs SET status = 'cancelled', lease_token = NULL, lease_expires_at = NULL,
                    finished_at = clock_timestamp(), error_code = 'consent_revoked'
                    WHERE user_id = owner_id AND status IN ('queued','running');
                UPDATE app.usage_reservations r SET status = 'released'
                    WHERE r.user_id = owner_id AND r.status = 'reserved'
                      AND EXISTS (SELECT FROM app.ai_jobs j WHERE j.id = r.ai_job_id AND j.status = 'cancelled');
            END IF;
        END IF;
    END IF;
    RETURN jsonb_build_object('data',jsonb_build_object('disclosure',d,'granted',api_private.ai_consent(owner_id) IS NOT NULL),'request_id',rid);
EXCEPTION WHEN invalid_text_representation OR invalid_parameter_value OR not_null_violation THEN
    RETURN jsonb_build_object('error',jsonb_build_object('code','validation_failed','message','Refresh privacy settings and retry','request_id',rid));
END $$;
REVOKE ALL ON FUNCTION app.api_v1_ai_consent(jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION app.api_v1_ai_consent(jsonb) TO authenticated;

CREATE FUNCTION app.jobs_enqueue_without_consent(owner_id uuid, operation_id uuid, job_kind text, payload jsonb,
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
           OR NOT EXISTS (SELECT FROM app.usage_reservations r WHERE r.ai_job_id = j.id AND r.units = jobs_enqueue_without_consent.units) THEN
            RAISE EXCEPTION 'Idempotency conflict' USING ERRCODE = '22023';
        END IF;
    END IF;
    RETURN j.id;
END $$;
REVOKE ALL ON FUNCTION app.jobs_enqueue_without_consent(uuid,uuid,text,jsonb,integer) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION app.jobs_enqueue_without_consent(uuid,uuid,text,jsonb,integer) FROM service_role;
CREATE OR REPLACE FUNCTION app.jobs_enqueue(owner_id uuid, operation_id uuid, job_kind text, payload jsonb, units integer DEFAULT 1) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
DECLARE consent uuid; job uuid;
BEGIN
    PERFORM 1 FROM app.profiles WHERE user_id = owner_id AND deleted_at IS NULL FOR UPDATE;
    consent := api_private.ai_consent(owner_id);
    IF consent IS NULL THEN RAISE EXCEPTION 'AI consent required' USING ERRCODE = '22023'; END IF;
    job := app.jobs_enqueue_without_consent(owner_id,operation_id,job_kind,payload,units);
    UPDATE app.ai_jobs SET consent_event_id = consent WHERE id = job AND consent_event_id IS NULL;
    RETURN job;
END $$;
REVOKE ALL ON FUNCTION app.jobs_enqueue(uuid,uuid,text,jsonb,integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION app.jobs_enqueue(uuid,uuid,text,jsonb,integer) TO service_role;

-- Must run immediately before invoking the external adapter, including every retry.
-- This commit is the dispatch authorization boundary; already dispatched requests cannot be recalled.
CREATE FUNCTION app.jobs_authorize_dispatch(job_id uuid, token uuid) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
DECLARE owner_id uuid; j app.ai_jobs%ROWTYPE;
BEGIN
    SELECT user_id INTO owner_id FROM app.ai_jobs WHERE id = job_id;
    PERFORM 1 FROM app.profiles WHERE user_id = owner_id FOR UPDATE;
    SELECT * INTO j FROM app.ai_jobs WHERE id = job_id FOR UPDATE;
    IF NOT FOUND OR j.status <> 'running' OR j.lease_token IS DISTINCT FROM token
        OR j.lease_expires_at <= clock_timestamp() THEN RETURN false; END IF;
    IF j.consent_event_id IS DISTINCT FROM api_private.ai_consent(owner_id)
       OR j.consent_event_id IS NULL
       OR NOT EXISTS (SELECT FROM app.profiles WHERE user_id = owner_id AND deleted_at IS NULL) THEN
        UPDATE app.ai_jobs SET status = 'cancelled', lease_token = NULL, lease_expires_at = NULL,
            finished_at = clock_timestamp(), error_code = 'consent_required' WHERE id = job_id;
        UPDATE app.usage_reservations SET status = 'released' WHERE ai_job_id = job_id AND status = 'reserved';
        RETURN false;
    END IF;
    RETURN true;
END $$;
REVOKE ALL ON FUNCTION app.jobs_authorize_dispatch(uuid,uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION app.jobs_authorize_dispatch(uuid,uuid) TO service_role;
