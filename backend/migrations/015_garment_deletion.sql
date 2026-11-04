-- Keep a scrubbed identity tombstone permanently: stale inserts cannot reuse UUIDs.
-- Physical photo cleanup uses the existing durable image_uploads ledger/sweeper.
CREATE FUNCTION app.api_v1_delete_garment(request jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
DECLARE
    owner_id uuid := auth.uid();
    request_id uuid := gen_random_uuid();
    target uuid;
    operation uuid;
    previous api_private.mutations%ROWTYPE;
    result jsonb;
BEGIN
    IF owner_id IS NULL THEN
        RETURN jsonb_build_object('error',jsonb_build_object('code','unauthorized','message','Sign in required','request_id',request_id));
    END IF;
    PERFORM 1 FROM app.profiles WHERE user_id = owner_id AND deleted_at IS NULL FOR SHARE;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('error',jsonb_build_object('code','account_unavailable','message','Account unavailable','request_id',request_id));
    END IF;
    IF jsonb_typeof(request) IS DISTINCT FROM 'object'
       OR NOT request ?& ARRAY['operationID','garmentID']
       OR request - ARRAY['operationID','garmentID'] <> '{}'::jsonb THEN
        RAISE EXCEPTION USING ERRCODE = '22023';
    END IF;
    target := (request->>'garmentID')::uuid;
    operation := (request->>'operationID')::uuid;
    IF target IS NULL OR operation IS NULL THEN RAISE EXCEPTION USING ERRCODE = '22023'; END IF;
    INSERT INTO api_private.mutations VALUES (owner_id,operation,request,NULL) ON CONFLICT DO NOTHING;
    SELECT * INTO previous FROM api_private.mutations m WHERE m.user_id=owner_id AND m.operation_id=operation FOR UPDATE;
    IF previous.request <> request THEN
        RETURN jsonb_build_object('error',jsonb_build_object('code','idempotency_conflict','message','Operation ID already used','request_id',request_id));
    END IF;
    IF previous.response IS NOT NULL THEN RETURN previous.response; END IF;
    -- Also fence a draft whose create never arrived, including concurrent creates.
    INSERT INTO app.garments(id,user_id,name,category,deleted_at)
        VALUES(target,owner_id,'Deleted','other',now()) ON CONFLICT DO NOTHING;
    PERFORM 1 FROM app.garments WHERE id=target AND user_id=owner_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE = '22023'; END IF;
    UPDATE app.garments SET deleted_at=now(), name='Deleted', category='other',
        subcategory=NULL, colors='{}', pattern=NULL, seasons='{}', formality=NULL,
        price_grosz=NULL, brand=NULL, purchased_on=NULL, estimated_prior_wears=0,
        tracking_start_date=NULL, archived_at=NULL, availability='unavailable'
        WHERE id=target AND user_id=owner_id AND deleted_at IS NULL;
    DELETE FROM app.garment_images WHERE user_id=owner_id AND garment_id=target;
    DELETE FROM app.outfit_items WHERE user_id=owner_id AND garment_id=target;
    DELETE FROM app.wear_event_items WHERE user_id=owner_id AND garment_id=target;
    DELETE FROM app.trip_items WHERE user_id=owner_id AND garment_id=target;
    UPDATE app.purchase_candidates SET purchased_garment_id=NULL
        WHERE user_id=owner_id AND purchased_garment_id=target AND deleted_at IS NULL;
    DELETE FROM app.purchase_candidates WHERE user_id=owner_id AND purchased_garment_id=target AND deleted_at IS NOT NULL;
    -- Derived history/CPW reads now use the remaining membership, never a stored counter.
    result := jsonb_build_object('data',true,'request_id',request_id);
    UPDATE api_private.mutations m SET response=result WHERE m.user_id=owner_id AND m.operation_id=operation;
    RETURN result;
EXCEPTION WHEN invalid_text_representation OR invalid_parameter_value THEN
    RETURN jsonb_build_object('error',jsonb_build_object('code','validation_failed','message','Invalid deletion','request_id',request_id));
END $$;
REVOKE ALL ON FUNCTION app.api_v1_delete_garment(jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION app.api_v1_delete_garment(jsonb) TO authenticated;
