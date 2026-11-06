-- Keep actual charged calls counted after terminal failure; release only unused repair capacity.
CREATE OR REPLACE FUNCTION app.jobs_enqueue(owner_id uuid,operation_id uuid,job_kind text,payload jsonb,units integer DEFAULT 1) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE policy api_private.ai_policy%ROWTYPE; day_start timestamptz := date_trunc('day',clock_timestamp() AT TIME ZONE 'UTC') AT TIME ZONE 'UTC';
    used_global bigint; used_user bigint; reserve_units integer; admitted uuid; replay_units integer;
BEGIN
    IF units IS NULL OR units<1 OR units>500000 THEN RAISE EXCEPTION 'Invalid units' USING ERRCODE='22023'; END IF;
    reserve_units := units * CASE WHEN job_kind IN('outfit_generation','purchase_fit') THEN 2 ELSE 1 END;
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
    -- A failed job releases its unused repair reservation, not its dispatched spend.
    SELECT coalesce(sum(CASE WHEN r.status='released' THEN
        coalesce((SELECT sum(d.units) FROM api_private.ai_dispatch_receipts d
          WHERE d.job_id=r.ai_job_id AND d.dispatched_at>=day_start),0)
        ELSE r.units END),0) INTO used_user FROM app.usage_reservations r
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
