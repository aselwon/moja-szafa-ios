-- Status changes preserve prices, images, estimates and historical relations.
-- Omitted archived preserves existing state for old clients/outbox records.
CREATE OR REPLACE FUNCTION app.api_v1_save_garment(request jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
DECLARE
    owner_id uuid := auth.uid();
    request_id uuid := gen_random_uuid();
    v_operation_id uuid;
    garment_id uuid;
    base_version bigint;
    body jsonb;
    previous api_private.mutations%ROWTYPE;
    garment app.garments%ROWTYPE;
    result jsonb;
BEGIN
    IF owner_id IS NULL THEN
        RETURN jsonb_build_object('error', jsonb_build_object('code','unauthorized','message','Sign in required','request_id',request_id));
    END IF;
    PERFORM 1 FROM app.profiles WHERE user_id = owner_id AND deleted_at IS NULL FOR SHARE;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('error', jsonb_build_object('code','account_unavailable','message','Account unavailable','request_id',request_id));
    END IF;
    IF jsonb_typeof(request) IS DISTINCT FROM 'object'
       OR NOT request ?& ARRAY['operation_id','garment_id','base_version','garment']
       OR request - ARRAY['operation_id','garment_id','base_version','garment'] <> '{}'::jsonb THEN
        RAISE EXCEPTION USING ERRCODE = '22023';
    END IF;
    v_operation_id := (request->>'operation_id')::uuid;
    garment_id := (request->>'garment_id')::uuid;
    base_version := (request->>'base_version')::bigint;
    body := request->'garment';
    IF v_operation_id IS NULL OR garment_id IS NULL OR (base_version IS NOT NULL AND base_version < 1)
       OR jsonb_typeof(body) IS DISTINCT FROM 'object'
       OR NOT body ?& ARRAY['name','category','price_grosz','availability']
       OR (body ? 'archived' AND jsonb_typeof(body->'archived') IS DISTINCT FROM 'boolean')
       OR body - ARRAY['name','category','price_grosz','availability','archived'] <> '{}'::jsonb
       OR jsonb_typeof(body->'name') IS DISTINCT FROM 'string'
       OR length(body->>'name') NOT BETWEEN 1 AND 200
       OR (body->>'name') !~ '[^[:space:]]'
       OR (body->>'category') IS NULL
       OR (body->>'category') NOT IN ('top','bottom','shoes','dress','jumpsuit','outerwear','accessory','other')
       OR (body->>'availability') IS NULL
       OR (body->>'availability') NOT IN ('available','laundry','unavailable')
       OR (body->'price_grosz' <> 'null'::jsonb AND
           (jsonb_typeof(body->'price_grosz') <> 'number' OR (body->>'price_grosz') !~ '^[0-9]+$'))
       OR (request->'base_version' <> 'null'::jsonb AND
           (jsonb_typeof(request->'base_version') <> 'number' OR (request->>'base_version') !~ '^[0-9]+$')) THEN
        RAISE EXCEPTION USING ERRCODE = '22023';
    END IF;
    INSERT INTO api_private.mutations VALUES (owner_id, v_operation_id, request, NULL)
        ON CONFLICT DO NOTHING;
    SELECT * INTO previous FROM api_private.mutations m
        WHERE m.user_id = owner_id AND m.operation_id = v_operation_id FOR UPDATE;
    IF previous.request <> request THEN
        RETURN jsonb_build_object('error',jsonb_build_object('code','idempotency_conflict','message','Operation ID already used for different content','request_id',request_id));
    END IF;
    IF previous.response IS NOT NULL THEN RETURN previous.response; END IF;
    IF base_version IS NULL THEN
        INSERT INTO app.garments(id,user_id,name,category,price_grosz,availability,archived_at)
        VALUES (garment_id,owner_id,body->>'name',body->>'category',(body->>'price_grosz')::bigint,body->>'availability',CASE WHEN (body->>'archived')::boolean THEN now() ELSE NULL END)
        RETURNING * INTO garment;
    ELSE
        UPDATE app.garments g SET name = body->>'name', category = body->>'category',
            price_grosz = (body->>'price_grosz')::bigint, availability = body->>'availability',
            archived_at = CASE WHEN NOT body ? 'archived' THEN g.archived_at
                WHEN (body->>'archived')::boolean THEN coalesce(g.archived_at,now()) ELSE NULL END
        WHERE g.id = garment_id AND g.user_id = owner_id AND g.version = base_version AND g.deleted_at IS NULL
        RETURNING * INTO garment;
        IF NOT FOUND THEN
            RAISE EXCEPTION USING ERRCODE = 'P0002';
        END IF;
    END IF;
    result := jsonb_build_object('data',jsonb_build_object('id',garment.id,'version',garment.version,
        'name',garment.name,'category',garment.category,'price_grosz',garment.price_grosz,
        'availability',garment.availability,'archived',garment.archived_at IS NOT NULL),'request_id',request_id);
    UPDATE api_private.mutations m SET response = result
        WHERE m.user_id = owner_id AND m.operation_id = v_operation_id;
    RETURN result;
EXCEPTION
    WHEN invalid_text_representation OR numeric_value_out_of_range OR invalid_parameter_value OR check_violation THEN
        RETURN jsonb_build_object('error',jsonb_build_object('code','validation_failed','message','Invalid request','request_id',request_id));
    WHEN unique_violation OR no_data_found THEN
        RETURN jsonb_build_object('error',jsonb_build_object('code','version_conflict','message','Record changed or unavailable','request_id',request_id));
    WHEN OTHERS THEN
        RETURN jsonb_build_object('error',jsonb_build_object('code','internal_error','message','Request could not be completed','request_id',request_id));
END $$;

CREATE OR REPLACE FUNCTION app.api_v1_sync_snapshot(request jsonb) RETURNS jsonb
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
            'metadata',CASE WHEN g.deleted_at IS NULL THEN api_private.wardrobe_item(g) ELSE NULL END,
            'fields',jsonb_build_object('name',g.name,'category',g.category,'price_grosz',g.price_grosz,'availability',g.availability,'archived',g.archived_at IS NOT NULL)) ORDER BY g.id),'[]'::jsonb)
            FROM app.garments g WHERE g.user_id = owner_id),
        'wears', (SELECT coalesce(jsonb_agg(jsonb_build_object(
            'id',w.id,'version',w.version,'deleted',w.deleted_at IS NOT NULL,
            'wornOn',to_char(w.worn_on,'YYYY-MM-DD'),'timezone',w.timezone,
            'garmentIDs',(SELECT coalesce(jsonb_agg(i.garment_id ORDER BY i.garment_id),'[]'::jsonb)
                FROM app.wear_event_items i WHERE i.user_id = owner_id AND i.wear_event_id = w.id AND i.deleted_at IS NULL)) ORDER BY w.id),'[]'::jsonb)
            FROM app.wear_events w WHERE w.user_id = owner_id)) INTO result;
    RETURN jsonb_build_object('data',result,'request_id',request_id);
END $$;

