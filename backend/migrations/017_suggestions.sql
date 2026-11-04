-- Only the latest completed outfit result is exposed; input and telemetry remain private.
CREATE FUNCTION app.api_v1_latest_suggestions(request jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
DECLARE owner_id uuid := auth.uid(); request_id uuid := gen_random_uuid(); result jsonb;
BEGIN
    IF owner_id IS NULL THEN
        RETURN jsonb_build_object('error',jsonb_build_object('code','unauthorized','message','Sign in required','request_id',request_id));
    END IF;
    IF NOT EXISTS (SELECT FROM app.profiles WHERE user_id = owner_id AND deleted_at IS NULL) THEN
        RETURN jsonb_build_object('error',jsonb_build_object('code','account_unavailable','message','Account unavailable','request_id',request_id));
    END IF;
    IF request IS DISTINCT FROM '{}'::jsonb THEN
        RETURN jsonb_build_object('error',jsonb_build_object('code','validation_failed','message','Expected empty request','request_id',request_id));
    END IF;
    SELECT p.result->'result' INTO result
        FROM app.ai_jobs j JOIN api_private.job_payloads p ON p.job_id = j.id
        WHERE j.user_id = owner_id AND j.deleted_at IS NULL
          AND j.kind = 'outfit_generation' AND j.status = 'succeeded'
        ORDER BY j.finished_at DESC, j.id DESC LIMIT 1;
    RETURN jsonb_build_object('data',result,'request_id',request_id);
END $$;
REVOKE ALL ON FUNCTION app.api_v1_latest_suggestions(jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION app.api_v1_latest_suggestions(jsonb) TO authenticated;

-- Keep the eligibility check and the existing idempotent save in one transaction.
CREATE FUNCTION app.api_v1_save_suggestion(request jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
DECLARE owner_id uuid := auth.uid(); request_id uuid := gen_random_uuid(); ids uuid[];
BEGIN
    -- The existing RPC handles auth, exact shape, replay and version conflicts.
    -- A successful replay must still work after a garment moves to laundry.
    IF owner_id IS NULL OR EXISTS (SELECT FROM api_private.mutations m
        WHERE m.user_id = owner_id AND m.operation_id = (api_v1_save_suggestion.request->>'operationID')::uuid
          AND m.response IS NOT NULL) THEN
        RETURN app.api_v1_save_outfit(request);
    END IF;
    SELECT array_agg(value::uuid) INTO ids FROM jsonb_array_elements_text(request->'garmentIDs');
    PERFORM g.id FROM app.garments g WHERE g.user_id = owner_id AND g.id = ANY(ids) ORDER BY g.id FOR SHARE;
    IF cardinality(ids) IS NULL OR (SELECT count(*) FROM app.garments g
        WHERE g.user_id = owner_id AND g.id = ANY(ids) AND g.deleted_at IS NULL
          AND g.archived_at IS NULL AND g.availability = 'available') <> cardinality(ids) THEN
        RAISE EXCEPTION USING ERRCODE = '22023';
    END IF;
    RETURN app.api_v1_save_outfit(request);
EXCEPTION WHEN invalid_text_representation OR invalid_parameter_value THEN
    RETURN jsonb_build_object('error',jsonb_build_object('code','validation_failed','message','Suggestion items unavailable','request_id',request_id));
END $$;
REVOKE ALL ON FUNCTION app.api_v1_save_suggestion(jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION app.api_v1_save_suggestion(jsonb) TO authenticated;
