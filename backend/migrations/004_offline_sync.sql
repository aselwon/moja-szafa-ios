-- Full, transactionally consistent reconciliation, including tombstones. No
-- timestamp cursor: concurrent commits cannot fall behind a client's watermark.
CREATE FUNCTION app.api_v1_sync_snapshot(request jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
DECLARE
    owner_id uuid := auth.uid();
    request_id uuid := gen_random_uuid();
    result jsonb;
BEGIN
    IF owner_id IS NULL THEN
        RETURN jsonb_build_object('error',jsonb_build_object('code','unauthorized','message','Sign in required','request_id',request_id));
    END IF;
    PERFORM 1 FROM app.profiles WHERE user_id = owner_id AND deleted_at IS NULL FOR SHARE;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('error',jsonb_build_object('code','account_unavailable','message','Account unavailable','request_id',request_id));
    END IF;
    IF request IS DISTINCT FROM '{}'::jsonb THEN
        RETURN jsonb_build_object('error',jsonb_build_object('code','validation_failed','message','Expected empty request','request_id',request_id));
    END IF;
    SELECT jsonb_build_object(
        'accountID', owner_id,
        'garments', (SELECT coalesce(jsonb_agg(jsonb_build_object(
            'id',g.id,'version',g.version,'deleted',g.deleted_at IS NOT NULL,
            'fields',jsonb_build_object('name',g.name,'category',g.category,'price_grosz',g.price_grosz,'availability',g.availability)) ORDER BY g.id),'[]'::jsonb)
            FROM app.garments g WHERE g.user_id = owner_id),
        'wears', (SELECT coalesce(jsonb_agg(jsonb_build_object(
            'id',w.id,'version',w.version,'deleted',w.deleted_at IS NOT NULL,
            'wornOn',to_char(w.worn_on,'YYYY-MM-DD'),'timezone',w.timezone,
            'garmentIDs',(SELECT coalesce(jsonb_agg(i.garment_id ORDER BY i.garment_id),'[]'::jsonb)
                FROM app.wear_event_items i WHERE i.user_id = owner_id AND i.wear_event_id = w.id AND i.deleted_at IS NULL)) ORDER BY w.id),'[]'::jsonb)
            FROM app.wear_events w WHERE w.user_id = owner_id)) INTO result;
    RETURN jsonb_build_object('data',result,'request_id',request_id);
END $$;

-- Append-only wear creation for offline sync. Editing/undo UI remains T034.
-- Historical IDs and local DATE are immutable input, never inferred from outfits.
CREATE FUNCTION app.api_v1_save_wear(request jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
DECLARE
    owner_id uuid := auth.uid();
    request_id uuid := gen_random_uuid();
    operation_id uuid;
    wear_id uuid;
    body jsonb;
    garment_ids uuid[];
    previous api_private.mutations%ROWTYPE;
    result jsonb;
    garment_id uuid;
BEGIN
    IF owner_id IS NULL THEN
        RETURN jsonb_build_object('error',jsonb_build_object('code','unauthorized','message','Sign in required','request_id',request_id));
    END IF;
    -- Same lock ordering as garment writes. A deletion that has committed wins
    -- even over a previously successful operation's replay response.
    PERFORM 1 FROM app.profiles WHERE user_id = owner_id AND deleted_at IS NULL FOR SHARE;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('error',jsonb_build_object('code','account_unavailable','message','Account unavailable','request_id',request_id));
    END IF;
    body := request->'wear';
    IF jsonb_typeof(request) IS DISTINCT FROM 'object'
       OR NOT request ?& ARRAY['operationID','wear'] OR request - ARRAY['operationID','wear'] <> '{}'::jsonb
       OR jsonb_typeof(body) IS DISTINCT FROM 'object'
       OR NOT body ?& ARRAY['id','version','deleted','wornOn','timezone','garmentIDs']
       OR body - ARRAY['id','version','deleted','wornOn','timezone','garmentIDs'] <> '{}'::jsonb
       OR body->'version' IS DISTINCT FROM '0'::jsonb OR body->'deleted' IS DISTINCT FROM 'false'::jsonb
       OR jsonb_typeof(body->'garmentIDs') IS DISTINCT FROM 'array'
       OR jsonb_typeof(body->'wornOn') IS DISTINCT FROM 'string'
       OR (body->>'wornOn') !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
       OR NOT EXISTS (SELECT FROM pg_timezone_names WHERE name = body->>'timezone') THEN
        RAISE EXCEPTION USING ERRCODE = '22023';
    END IF;
    operation_id := (request->>'operationID')::uuid;
    wear_id := (body->>'id')::uuid;
    SELECT array_agg(value::uuid ORDER BY value::uuid) INTO garment_ids FROM jsonb_array_elements_text(body->'garmentIDs');
    IF operation_id IS NULL OR wear_id IS NULL OR coalesce(cardinality(garment_ids),0) NOT BETWEEN 1 AND 100
       OR cardinality(garment_ids) <> (SELECT count(DISTINCT id) FROM unnest(garment_ids) id) THEN
        RAISE EXCEPTION USING ERRCODE = '22023';
    END IF;
    INSERT INTO api_private.mutations VALUES (owner_id, operation_id, request, NULL) ON CONFLICT DO NOTHING;
    SELECT * INTO previous FROM api_private.mutations m
        WHERE m.user_id = owner_id AND m.operation_id = api_v1_save_wear.operation_id FOR UPDATE;
    IF previous.request <> request THEN
        RETURN jsonb_build_object('error',jsonb_build_object('code','idempotency_conflict','message','Operation ID already used','request_id',request_id));
    END IF;
    IF previous.response IS NOT NULL THEN RETURN previous.response; END IF;
    -- Lock in UUID order against concurrent garment tombstones/deletion.
    FOREACH garment_id IN ARRAY garment_ids LOOP
        PERFORM 1 FROM app.garments g WHERE g.user_id = owner_id AND g.id = garment_id AND g.deleted_at IS NULL FOR SHARE;
        IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE = '22023'; END IF;
    END LOOP;
    INSERT INTO app.wear_events(id,user_id,worn_on,timezone,client_request_id)
        VALUES (wear_id,owner_id,(body->>'wornOn')::date,body->>'timezone',operation_id);
    INSERT INTO app.wear_event_items(user_id,wear_event_id,garment_id)
        SELECT owner_id,wear_id,id FROM unnest(garment_ids) id;
    result := jsonb_build_object('data',body || jsonb_build_object('version',1),'request_id',request_id);
    UPDATE api_private.mutations m SET response = result
        WHERE m.user_id = owner_id AND m.operation_id = api_v1_save_wear.operation_id;
    RETURN result;
EXCEPTION
    WHEN invalid_text_representation OR invalid_datetime_format OR datetime_field_overflow
         OR invalid_parameter_value OR check_violation OR not_null_violation THEN
        RETURN jsonb_build_object('error',jsonb_build_object('code','validation_failed','message','Invalid wear request','request_id',request_id));
    WHEN unique_violation THEN
        RETURN jsonb_build_object('error',jsonb_build_object('code','version_conflict','message','Wear already exists','request_id',request_id));
    WHEN OTHERS THEN
        RETURN jsonb_build_object('error',jsonb_build_object('code','internal_error','message','Request could not be completed','request_id',request_id));
END $$;
REVOKE ALL ON FUNCTION app.api_v1_sync_snapshot(jsonb), app.api_v1_save_wear(jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION app.api_v1_sync_snapshot(jsonb), app.api_v1_save_wear(jsonb) TO authenticated;
