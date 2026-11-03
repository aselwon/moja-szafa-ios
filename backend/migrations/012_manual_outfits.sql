-- Outfit membership is mutable; wear_event_items is an independent snapshot.
CREATE FUNCTION api_private.outfit_item(o app.outfits) RETURNS jsonb
LANGUAGE sql STABLE SET search_path = pg_catalog AS $$
    SELECT jsonb_build_object('id',o.id,'version',o.version,'name',o.name,'favorite',o.favorite,
        'garments',coalesce((SELECT jsonb_agg(api_private.wardrobe_item(g) ORDER BY i.position)
            FROM app.outfit_items i JOIN app.garments g ON g.user_id = i.user_id AND g.id = i.garment_id
            WHERE i.user_id = o.user_id AND i.outfit_id = o.id AND i.deleted_at IS NULL AND g.deleted_at IS NULL),'[]'::jsonb));
$$;
REVOKE ALL ON FUNCTION api_private.outfit_item(app.outfits) FROM PUBLIC, anon, authenticated;

CREATE FUNCTION app.api_v1_save_outfit(request jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
DECLARE
    owner_id uuid := auth.uid();
    request_id uuid := gen_random_uuid();
    v_operation uuid;
    v_id uuid;
    v_base bigint;
    ids uuid[];
    previous api_private.mutations%ROWTYPE;
    outfit app.outfits%ROWTYPE;
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
        OR NOT request ?& ARRAY['operationID','id','baseVersion','name','favorite','garmentIDs']
        OR request - ARRAY['operationID','id','baseVersion','name','favorite','garmentIDs'] <> '{}'
        OR jsonb_typeof(request->'name') IS DISTINCT FROM 'string'
        OR length(request->>'name') NOT BETWEEN 1 AND 200 OR request->>'name' !~ '[^[:space:]]'
        OR jsonb_typeof(request->'favorite') IS DISTINCT FROM 'boolean'
        OR jsonb_typeof(request->'baseVersion') IS DISTINCT FROM 'number'
        OR request->>'baseVersion' !~ '^[0-9]+$'
        OR jsonb_typeof(request->'garmentIDs') IS DISTINCT FROM 'array'
    THEN RAISE EXCEPTION USING ERRCODE = '22023'; END IF;
    v_operation := (request->>'operationID')::uuid;
    v_id := (request->>'id')::uuid;
    v_base := (request->>'baseVersion')::bigint;
    SELECT array_agg(value::uuid) INTO ids FROM jsonb_array_elements_text(request->'garmentIDs');
    IF v_operation IS NULL OR v_id IS NULL OR cardinality(ids) IS NULL OR cardinality(ids) NOT BETWEEN 1 AND 100
        OR (SELECT count(DISTINCT id) FROM unnest(ids) id) <> cardinality(ids)
    THEN RAISE EXCEPTION USING ERRCODE = '22023'; END IF;
    INSERT INTO api_private.mutations VALUES(owner_id,v_operation,request,NULL) ON CONFLICT DO NOTHING;
    SELECT * INTO previous FROM api_private.mutations m WHERE m.user_id = owner_id AND m.operation_id = v_operation FOR UPDATE;
    IF previous.request <> request THEN
        RETURN jsonb_build_object('error',jsonb_build_object('code','idempotency_conflict','message','Operation already used','request_id',request_id));
    END IF;
    IF previous.response IS NOT NULL THEN RETURN previous.response; END IF;
    -- Locks prevent deletion/archive changes during validation and membership write.
    PERFORM g.id FROM app.garments g WHERE g.user_id = owner_id AND g.id = ANY(ids) AND g.deleted_at IS NULL ORDER BY g.id FOR SHARE;
    IF (SELECT count(*) FROM app.garments g WHERE g.user_id = owner_id AND g.id = ANY(ids) AND g.deleted_at IS NULL) <> cardinality(ids)
    THEN RAISE EXCEPTION USING ERRCODE = '22023'; END IF;
    IF v_base = 0 THEN
        INSERT INTO app.outfits(id,user_id,name,favorite) VALUES(v_id,owner_id,btrim(request->>'name'),(request->>'favorite')::boolean)
            RETURNING * INTO outfit;
    ELSE
        UPDATE app.outfits o SET name = btrim(request->>'name'), favorite = (request->>'favorite')::boolean
            WHERE o.id = v_id AND o.user_id = owner_id AND o.version = v_base AND o.deleted_at IS NULL RETURNING * INTO outfit;
        IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE = 'P0002'; END IF;
    END IF;
    DELETE FROM app.outfit_items WHERE user_id = owner_id AND outfit_id = v_id;
    INSERT INTO app.outfit_items(user_id,outfit_id,garment_id,position)
        SELECT owner_id,v_id,id,(ordinality - 1)::integer FROM unnest(ids) WITH ORDINALITY AS selected(id,ordinality);
    result := jsonb_build_object('data',api_private.outfit_item(outfit),'request_id',request_id);
    UPDATE api_private.mutations m SET response = result WHERE m.user_id = owner_id AND m.operation_id = v_operation;
    RETURN result;
EXCEPTION
    WHEN invalid_text_representation OR numeric_value_out_of_range OR invalid_parameter_value OR check_violation OR foreign_key_violation THEN
        RETURN jsonb_build_object('error',jsonb_build_object('code','validation_failed','message','Invalid outfit','request_id',request_id));
    WHEN unique_violation OR no_data_found THEN
        RETURN jsonb_build_object('error',jsonb_build_object('code','version_conflict','message','Outfit changed; reload before editing','request_id',request_id));
END $$;

CREATE FUNCTION app.api_v1_list_outfits(request jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
DECLARE
    owner_id uuid := auth.uid();
    request_id uuid := gen_random_uuid();
    page_limit integer;
    after_id uuid;
    rows jsonb;
    next_cursor uuid;
BEGIN
    IF owner_id IS NULL THEN
        RETURN jsonb_build_object('error',jsonb_build_object('code','unauthorized','message','Sign in required','request_id',request_id));
    END IF;
    IF NOT EXISTS (SELECT FROM app.profiles WHERE user_id = owner_id AND deleted_at IS NULL) THEN
        RETURN jsonb_build_object('error',jsonb_build_object('code','account_unavailable','message','Account unavailable','request_id',request_id));
    END IF;
    IF jsonb_typeof(request) IS DISTINCT FROM 'object' OR NOT request ?& ARRAY['limit','cursor']
        OR request - ARRAY['limit','cursor'] <> '{}' OR jsonb_typeof(request->'limit') IS DISTINCT FROM 'number'
        OR request->>'limit' !~ '^[0-9]+$' THEN RAISE EXCEPTION USING ERRCODE = '22023'; END IF;
    page_limit := (request->>'limit')::integer;
    after_id := (request->>'cursor')::uuid;
    IF page_limit NOT BETWEEN 1 AND 100 THEN RAISE EXCEPTION USING ERRCODE = '22023'; END IF;
    SELECT coalesce(jsonb_agg(api_private.outfit_item(o::app.outfits) ORDER BY o.id),'[]'::jsonb) INTO rows
        FROM (SELECT * FROM app.outfits WHERE user_id = owner_id AND deleted_at IS NULL
            AND (after_id IS NULL OR id > after_id) ORDER BY id LIMIT page_limit + 1) o;
    IF jsonb_array_length(rows) > page_limit THEN
        rows := rows - page_limit;
        next_cursor := (rows->(page_limit - 1)->>'id')::uuid;
    END IF;
    RETURN jsonb_build_object('data',jsonb_build_object('items',rows,'nextCursor',next_cursor),'request_id',request_id);
EXCEPTION WHEN invalid_text_representation OR numeric_value_out_of_range OR invalid_parameter_value THEN
    RETURN jsonb_build_object('error',jsonb_build_object('code','validation_failed','message','Invalid pagination','request_id',request_id));
END $$;
REVOKE ALL ON FUNCTION app.api_v1_save_outfit(jsonb), app.api_v1_list_outfits(jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION app.api_v1_save_outfit(jsonb), app.api_v1_list_outfits(jsonb) TO authenticated;
