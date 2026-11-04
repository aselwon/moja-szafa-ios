-- Server-only policy. Disabled until disclosure, free provider and quotas are configured.
CREATE TABLE api_private.ai_policy (
    singleton boolean PRIMARY KEY DEFAULT true CHECK(singleton),
    enabled boolean NOT NULL DEFAULT false,
    image_enabled boolean NOT NULL DEFAULT false,
    daily_user_units integer NOT NULL DEFAULT 10 CHECK(daily_user_units BETWEEN 1 AND 1000000),
    daily_global_units integer NOT NULL DEFAULT 100 CHECK(daily_global_units BETWEEN 1 AND 1000000),
    recipient text NOT NULL DEFAULT 'Cloudflare Workers AI' CHECK(length(recipient) BETWEEN 1 AND 200)
);
INSERT INTO api_private.ai_policy(singleton) VALUES(true);
CREATE TABLE api_private.ai_daily_dispatch (
    day date PRIMARY KEY, units bigint NOT NULL CHECK(units>=0)
);
CREATE TABLE api_private.ai_dispatch_receipts (
    job_id uuid REFERENCES app.ai_jobs(id) ON DELETE CASCADE,
    provider_call integer NOT NULL CHECK(provider_call IN(1,2)),
    attempt integer NOT NULL, dispatched_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    units integer NOT NULL CHECK(units>0), telemetry jsonb, PRIMARY KEY(job_id,provider_call)
);
REVOKE ALL ON api_private.ai_policy,api_private.ai_daily_dispatch,api_private.ai_dispatch_receipts FROM PUBLIC,anon,authenticated,service_role;

ALTER FUNCTION app.jobs_enqueue(uuid,uuid,text,jsonb,integer) RENAME TO jobs_enqueue_with_consent;
REVOKE ALL ON FUNCTION app.jobs_enqueue_with_consent(uuid,uuid,text,jsonb,integer) FROM PUBLIC,anon,authenticated,service_role;
CREATE FUNCTION app.jobs_enqueue(owner_id uuid,operation_id uuid,job_kind text,payload jsonb,units integer DEFAULT 1) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE policy api_private.ai_policy%ROWTYPE; day_start timestamptz := date_trunc('day',clock_timestamp() AT TIME ZONE 'UTC') AT TIME ZONE 'UTC';
    used_global bigint; used_user bigint; reserve_units integer; admitted uuid; replay_units integer;
BEGIN
    IF units IS NULL OR units<1 OR units>500000 THEN RAISE EXCEPTION 'Invalid units' USING ERRCODE='22023'; END IF;
    reserve_units := units * CASE WHEN job_kind='outfit_generation' THEN 2 ELSE 1 END;
    -- A single policy lock serializes admission and dispatch across every worker.
    SELECT * INTO STRICT policy FROM api_private.ai_policy FOR UPDATE;
    IF NOT policy.enabled OR (job_kind='image_analysis' AND NOT policy.image_enabled) THEN RAISE EXCEPTION 'AI disabled' USING ERRCODE='22023'; END IF;
    -- Preserve exact durable replay even when the remaining budget is now exhausted.
    IF EXISTS(SELECT FROM app.ai_jobs WHERE user_id=owner_id AND client_request_id=operation_id) THEN
        SELECT CASE WHEN j.pricing_version='call-credits-v1' THEN reserve_units ELSE units END INTO replay_units
          FROM app.ai_jobs j WHERE j.user_id=owner_id AND j.client_request_id=operation_id;
        RETURN app.jobs_enqueue_with_consent(owner_id,operation_id,job_kind,payload,replay_units);
    END IF;
    IF units IS NULL OR units<1 THEN RAISE EXCEPTION 'Invalid units' USING ERRCODE='22023'; END IF;
    SELECT coalesce(sum(r.units),0) INTO used_user FROM app.usage_reservations r
        WHERE r.user_id=owner_id AND (r.status='reserved' OR r.created_at>=day_start OR EXISTS(SELECT FROM api_private.ai_dispatch_receipts d WHERE d.job_id=r.ai_job_id AND d.dispatched_at>=day_start))
        AND (r.status IN('reserved','settled') OR EXISTS(SELECT FROM api_private.ai_dispatch_receipts d WHERE d.job_id=r.ai_job_id));
    SELECT coalesce(sum(greatest(0,r.units-coalesce((SELECT sum(d.units) FROM api_private.ai_dispatch_receipts d WHERE d.job_id=r.ai_job_id),0))),0) INTO used_global FROM app.usage_reservations r
        WHERE r.status='reserved' OR (r.status='settled' AND r.created_at>=day_start);
    used_global := used_global + coalesce((SELECT d.units FROM api_private.ai_daily_dispatch d WHERE d.day=(day_start AT TIME ZONE 'UTC')::date),0);
    IF used_user+reserve_units>policy.daily_user_units OR used_global+reserve_units>policy.daily_global_units THEN
        RAISE EXCEPTION 'AI quota exhausted' USING ERRCODE='22023'; END IF;
    admitted:=app.jobs_enqueue_with_consent(owner_id,operation_id,job_kind,payload,reserve_units);
    UPDATE app.ai_jobs SET pricing_version='call-credits-v1' WHERE id=admitted;
    RETURN admitted;
END $$;
REVOKE ALL ON FUNCTION app.jobs_enqueue(uuid,uuid,text,jsonb,integer) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION app.jobs_enqueue(uuid,uuid,text,jsonb,integer) TO service_role;

-- Each provider call is dispatched at most once, including process loss.
-- Outfits reserve two calls; the second requires durable malformed-JSON evidence.
-- Receipt means potentially spent: never refund an uncertain external response.
CREATE FUNCTION app.ai_runtime_dispatch(job_id uuid,token uuid,recipient text) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE policy api_private.ai_policy%ROWTYPE; amount integer; call_number integer := 1; j app.ai_jobs%ROWTYPE; current_day date := (clock_timestamp() AT TIME ZONE 'UTC')::date;
BEGIN
    SELECT * INTO STRICT policy FROM api_private.ai_policy FOR UPDATE;
    IF NOT policy.enabled OR policy.recipient IS DISTINCT FROM recipient
       OR NOT EXISTS(SELECT FROM api_private.ai_disclosure d WHERE d.recipient=ai_runtime_dispatch.recipient)
       OR NOT app.jobs_authorize_dispatch(job_id,token) THEN RETURN false; END IF;
    SELECT units INTO amount FROM app.usage_reservations r WHERE r.ai_job_id=job_id AND r.status='reserved';
    IF amount IS NULL THEN RETURN false; END IF;
    SELECT * INTO STRICT j FROM app.ai_jobs WHERE id=job_id;
    IF j.kind='image_analysis' AND NOT policy.image_enabled THEN RETURN false; END IF;
    IF EXISTS(SELECT FROM api_private.ai_dispatch_receipts d WHERE d.job_id=j.id) THEN
        IF j.kind<>'outfit_generation' OR j.pricing_version IS DISTINCT FROM 'call-credits-v1' OR NOT EXISTS(SELECT FROM api_private.ai_dispatch_receipts d
            WHERE d.job_id=j.id AND d.provider_call=1 AND d.attempt=j.attempts
              AND d.telemetry->>'status'='outfit_json_invalid') THEN RETURN false; END IF;
        call_number := 2;
    END IF;
    IF j.kind='outfit_generation' AND j.pricing_version='call-credits-v1' THEN amount := amount/2; END IF;
    IF coalesce((SELECT d.units FROM api_private.ai_daily_dispatch d WHERE d.day=current_day),0)+amount>policy.daily_global_units
      OR coalesce((SELECT sum(d.units) FROM api_private.ai_dispatch_receipts d JOIN app.ai_jobs q ON q.id=d.job_id
        WHERE q.user_id=j.user_id AND (d.dispatched_at AT TIME ZONE 'UTC')::date=current_day),0)+amount>policy.daily_user_units
      THEN RETURN false; END IF;
    INSERT INTO api_private.ai_dispatch_receipts(job_id,provider_call,attempt,units)
        VALUES(j.id,call_number,j.attempts,amount) ON CONFLICT DO NOTHING;
    IF NOT FOUND THEN RETURN false; END IF;
    INSERT INTO api_private.ai_daily_dispatch(day,units) VALUES(current_day,amount)
        ON CONFLICT(day) DO UPDATE SET units=api_private.ai_daily_dispatch.units+EXCLUDED.units;
    RETURN true;
END $$;

CREATE FUNCTION app.ai_runtime_input(job_id uuid,token uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE j app.ai_jobs%ROWTYPE; payload jsonb; items jsonb; image_key text;
BEGIN
    IF NOT app.jobs_authorize_dispatch(job_id,token) THEN RETURN NULL; END IF;
    SELECT * INTO STRICT j FROM app.ai_jobs WHERE id=job_id;
    SELECT input INTO payload FROM api_private.job_payloads WHERE job_payloads.job_id=j.id;
    IF j.kind='image_analysis' THEN
        SELECT i.object_key INTO image_key FROM app.garment_images i
            JOIN api_private.image_uploads u ON i.object_key=u.id::text || '/thumbnail.jpg' AND u.user_id=i.user_id AND u.state='ready'
            JOIN app.garments g
            ON g.user_id=i.user_id AND g.id=i.garment_id
            WHERE u.id=(payload->>'image_id')::uuid AND i.user_id=j.user_id AND i.status='ready'
              AND i.deleted_at IS NULL AND g.deleted_at IS NULL AND i.variant='thumbnail';
        IF image_key IS NULL THEN RETURN NULL; END IF;
        RETURN jsonb_build_object('object_key',image_key,'mimeType','image/jpeg');
    ELSIF j.kind='outfit_generation' THEN
        SELECT coalesce(jsonb_agg(jsonb_build_object('id',g.id,'user_id',g.user_id,'category',g.category,
            'colors',g.colors,'pattern',g.pattern,'seasons',g.seasons,'formality',g.formality,
            'availability',g.availability,'archived',g.archived_at IS NOT NULL)),'[]'::jsonb)
            INTO items FROM (SELECT * FROM app.garments WHERE user_id=j.user_id AND deleted_at IS NULL
                ORDER BY id LIMIT 1001) g;
        IF jsonb_array_length(items)>1000 THEN RETURN NULL; END IF;
        RETURN (payload - ARRAY['garments','user_id','owner','object_key','image_id']) || jsonb_build_object('garments',items);
    END IF;
    RETURN NULL;
END $$;

CREATE FUNCTION app.ai_runtime_telemetry(job_id uuid,attempt integer,provider_call integer,record jsonb) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
    IF jsonb_typeof(record) IS DISTINCT FROM 'object'
       OR record - ARRAY['provider','model','operation','prompt_version','latency_ms','usage','status'] <> '{}'::jsonb
       OR octet_length(record::text)>4096 THEN RETURN false; END IF;
    UPDATE api_private.ai_dispatch_receipts d SET telemetry=record
      WHERE d.job_id=ai_runtime_telemetry.job_id AND d.attempt=ai_runtime_telemetry.attempt AND d.provider_call=ai_runtime_telemetry.provider_call AND d.telemetry IS NULL;
    RETURN FOUND OR EXISTS(SELECT FROM api_private.ai_dispatch_receipts d WHERE d.job_id=ai_runtime_telemetry.job_id
      AND d.attempt=ai_runtime_telemetry.attempt AND d.provider_call=ai_runtime_telemetry.provider_call AND d.telemetry=record);
END $$;
REVOKE ALL ON FUNCTION app.ai_runtime_dispatch(uuid,uuid,text),app.ai_runtime_input(uuid,uuid),
    app.ai_runtime_telemetry(uuid,integer,integer,jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION app.ai_runtime_dispatch(uuid,uuid,text),app.ai_runtime_input(uuid,uuid),
    app.ai_runtime_telemetry(uuid,integer,integer,jsonb) TO service_role;

CREATE FUNCTION app.api_v1_generate_outfits(request jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE owner_id uuid:=auth.uid(); rid uuid:=gen_random_uuid(); operation uuid; pin uuid; count integer; job uuid; code text;
BEGIN
    IF owner_id IS NULL THEN RETURN jsonb_build_object('error',jsonb_build_object('code','unauthorized','message','Sign in required','request_id',rid)); END IF;
    IF NOT EXISTS(SELECT FROM app.profiles WHERE user_id=owner_id AND deleted_at IS NULL) THEN
        RETURN jsonb_build_object('error',jsonb_build_object('code','account_unavailable','message','Account unavailable','request_id',rid)); END IF;
    IF jsonb_typeof(request) IS DISTINCT FROM 'object' OR NOT request ?& ARRAY['operation_id','count','pinned_garment_id','preferences','occasion']
      OR request-ARRAY['operation_id','count','pinned_garment_id','preferences','occasion']<>'{}'::jsonb
      OR jsonb_typeof(request->'count') IS DISTINCT FROM 'number' OR request->>'count' !~ '^[0-9]+$'
      OR jsonb_typeof(request->'preferences') IS DISTINCT FROM 'object' OR NOT (request->'preferences') ?& ARRAY['colors','seasons']
      OR (request->'preferences')-ARRAY['colors','seasons']<>'{}'::jsonb
      OR jsonb_typeof(request#>'{preferences,colors}') IS DISTINCT FROM 'array'
      OR jsonb_typeof(request#>'{preferences,seasons}') IS DISTINCT FROM 'array'
      OR jsonb_typeof(request->'occasion') IS DISTINCT FROM 'object' OR NOT (request->'occasion') ? 'formality'
      OR (request->'occasion')-'formality'<>'{}'::jsonb THEN RAISE EXCEPTION 'Invalid request' USING ERRCODE='22023'; END IF;
    operation:=(request->>'operation_id')::uuid; pin:=(request->>'pinned_garment_id')::uuid; count:=(request->>'count')::integer;
    IF operation IS NULL OR count NOT BETWEEN 1 AND 10
      OR jsonb_array_length(request#>'{preferences,colors}')>13 OR jsonb_array_length(request#>'{preferences,seasons}')>4
      OR (SELECT count(DISTINCT c) FROM jsonb_array_elements_text(request#>'{preferences,colors}') c)<>jsonb_array_length(request#>'{preferences,colors}')
      OR (SELECT count(DISTINCT c) FROM jsonb_array_elements_text(request#>'{preferences,seasons}') c)<>jsonb_array_length(request#>'{preferences,seasons}')
      OR EXISTS(SELECT FROM jsonb_array_elements_text(request#>'{preferences,colors}') c WHERE c IS NULL OR c<>ALL(ARRAY['black','white','gray','beige','brown','red','orange','yellow','green','blue','purple','pink','other']))
      OR EXISTS(SELECT FROM jsonb_array_elements_text(request#>'{preferences,seasons}') c WHERE c IS NULL OR c<>ALL(ARRAY['spring','summer','autumn','winter']))
      OR (request#>'{occasion,formality}'<>'null'::jsonb AND (jsonb_typeof(request#>'{occasion,formality}')<>'number' OR request#>>'{occasion,formality}' !~ '^[1-5]$'))
      OR (pin IS NOT NULL AND NOT EXISTS(SELECT FROM app.garments WHERE id=pin AND user_id=owner_id AND deleted_at IS NULL AND archived_at IS NULL AND availability='available'))
      THEN RAISE EXCEPTION 'Invalid request' USING ERRCODE='22023'; END IF;
    job:=app.jobs_enqueue(owner_id,operation,'outfit_generation',request-'operation_id',1);
    RETURN jsonb_build_object('data',jsonb_build_object('job_id',job,'status',(SELECT status FROM app.ai_jobs WHERE id=job)),'request_id',rid);
EXCEPTION WHEN invalid_text_representation OR numeric_value_out_of_range OR invalid_parameter_value THEN
    code:=CASE SQLERRM WHEN 'AI disabled' THEN 'ai_disabled' WHEN 'AI quota exhausted' THEN 'quota_exceeded'
      WHEN 'AI consent required' THEN 'consent_required' ELSE 'validation_failed' END;
    RETURN jsonb_build_object('error',jsonb_build_object('code',code,'message','Request could not be accepted','request_id',rid));
WHEN OTHERS THEN RETURN jsonb_build_object('error',jsonb_build_object('code','internal_error','message','Request could not be completed','request_id',rid));
END $$;

CREATE FUNCTION app.api_v1_job_result(request jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE owner_id uuid:=auth.uid(); rid uuid:=gen_random_uuid(); job uuid; result jsonb;
BEGIN
    IF owner_id IS NULL THEN RETURN jsonb_build_object('error',jsonb_build_object('code','unauthorized','message','Sign in required','request_id',rid)); END IF;
    IF NOT EXISTS(SELECT FROM app.profiles WHERE user_id=owner_id AND deleted_at IS NULL) THEN
      RETURN jsonb_build_object('error',jsonb_build_object('code','account_unavailable','message','Account unavailable','request_id',rid)); END IF;
    IF jsonb_typeof(request) IS DISTINCT FROM 'object' OR NOT request ? 'job_id' OR request-'job_id'<>'{}'::jsonb THEN
      RAISE EXCEPTION 'Invalid request' USING ERRCODE='22023'; END IF;
    job:=(request->>'job_id')::uuid;
    IF job IS NULL THEN RAISE EXCEPTION 'Invalid request' USING ERRCODE='22023'; END IF;
    SELECT jsonb_build_object('job_id',j.id,'kind',j.kind,'status',j.status,'error_code',j.error_code,
      'result',CASE WHEN j.status='succeeded' THEN p.result->'result' ELSE NULL END) INTO result
      FROM app.ai_jobs j JOIN api_private.job_payloads p ON p.job_id=j.id
      WHERE j.id=job AND j.user_id=owner_id AND j.kind='outfit_generation' AND j.deleted_at IS NULL;
    IF result IS NULL THEN RETURN jsonb_build_object('error',jsonb_build_object('code','not_found','message','Job unavailable','request_id',rid)); END IF;
    RETURN jsonb_build_object('data',result,'request_id',rid);
EXCEPTION WHEN invalid_text_representation OR invalid_parameter_value THEN
    RETURN jsonb_build_object('error',jsonb_build_object('code','validation_failed','message','Invalid request','request_id',rid));
WHEN OTHERS THEN RETURN jsonb_build_object('error',jsonb_build_object('code','internal_error','message','Request could not be completed','request_id',rid));
END $$;
REVOKE ALL ON FUNCTION app.api_v1_generate_outfits(jsonb),app.api_v1_job_result(jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION app.api_v1_generate_outfits(jsonb),app.api_v1_job_result(jsonb) TO authenticated;
