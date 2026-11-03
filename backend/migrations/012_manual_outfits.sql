-- Manual outfit membership is independent of wear history.
CREATE FUNCTION api_private.outfit_item(o app.outfits) RETURNS jsonb
LANGUAGE sql STABLE SET search_path = pg_catalog AS $$
 SELECT jsonb_build_object('id',o.id,'version',o.version,'name',o.name,'favorite',o.favorite,
 'garmentIDs',(SELECT coalesce(jsonb_agg(i.garment_id ORDER BY i.position),'[]'::jsonb)
 FROM app.outfit_items i JOIN app.garments g ON g.user_id=i.user_id AND g.id=i.garment_id
 WHERE i.user_id=o.user_id AND i.outfit_id=o.id AND i.deleted_at IS NULL AND g.deleted_at IS NULL));
$$;
REVOKE ALL ON FUNCTION api_private.outfit_item(app.outfits) FROM PUBLIC, anon, authenticated;

CREATE FUNCTION app.api_v1_list_outfits(request jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
DECLARE owner_id uuid := auth.uid(); request_id uuid := gen_random_uuid(); rows jsonb;
BEGIN
 IF NOT EXISTS (SELECT FROM app.profiles WHERE user_id=owner_id AND deleted_at IS NULL) THEN
 RETURN jsonb_build_object('error',jsonb_build_object('code','account_unavailable','message','Account unavailable','request_id',request_id)); END IF;
 IF request IS DISTINCT FROM '{}'::jsonb THEN
 RETURN jsonb_build_object('error',jsonb_build_object('code','validation_failed','message','Expected empty request','request_id',request_id)); END IF;
 SELECT coalesce(jsonb_agg(api_private.outfit_item(o) ORDER BY o.created_at,o.id),'[]'::jsonb) INTO rows
 FROM app.outfits o WHERE o.user_id=owner_id AND o.deleted_at IS NULL;
 RETURN jsonb_build_object('data',rows,'request_id',request_id);
END $$;

CREATE FUNCTION app.api_v1_save_outfit(request jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
DECLARE
    owner_id uuid := auth.uid();
    request_id uuid := gen_random_uuid();
    v_operation_id uuid;
    outfit_id uuid;
    base_version bigint;
    body jsonb;
    previous api_private.mutations%ROWTYPE;
    outfit app.outfits%ROWTYPE;
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
       OR NOT request ?& ARRAY['operation_id','outfit_id','base_version','outfit']
       OR request - ARRAY['operation_id','outfit_id','base_version','outfit'] <> '{}'::jsonb THEN
        RAISE EXCEPTION USING ERRCODE = '22023';
    END IF;
    v_operation_id := (request->>'operation_id')::uuid;
    outfit_id := (request->>'outfit_id')::uuid;
    base_version := (request->>'base_version')::bigint;
    body := request->'outfit';
    IF v_operation_id IS NULL OR outfit_id IS NULL OR (base_version IS NOT NULL AND base_version < 1)
       OR jsonb_typeof(body) IS DISTINCT FROM 'object'
       OR NOT body ?& ARRAY['name','favorite','garmentIDs']
       OR body - ARRAY['name','favorite','garmentIDs'] <> '{}'
       OR jsonb_typeof(body->'name') IS DISTINCT FROM 'string'
       OR length(btrim(body->>'name')) NOT BETWEEN 1 AND 200
       OR (body->>'name') !~ '[^[:space:]]'
       OR jsonb_typeof(body->'favorite') IS DISTINCT FROM 'boolean'
       OR jsonb_typeof(body->'garmentIDs') IS DISTINCT FROM 'array'
       OR (request->'base_version' <> 'null'::jsonb AND
           (jsonb_typeof(request->'base_version') <> 'number' OR (request->>'base_version') !~ '^[0-9]+$')) THEN
        RAISE EXCEPTION USING ERRCODE = '22023';
    END IF;
    IF jsonb_array_length(body->'garmentIDs') NOT BETWEEN 1 AND 100 THEN
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
    -- Lock selected records against archive/delete while replacing membership.
    PERFORM g.id FROM app.garments g
        WHERE g.user_id = owner_id AND g.deleted_at IS NULL
          AND g.id IN (SELECT value::uuid FROM jsonb_array_elements_text(body->'garmentIDs'))
        ORDER BY g.id FOR SHARE;
    IF (SELECT count(*) FROM app.garments g WHERE g.user_id = owner_id AND g.deleted_at IS NULL
        AND g.id IN (SELECT value::uuid FROM jsonb_array_elements_text(body->'garmentIDs')))
        <> jsonb_array_length(body->'garmentIDs') THEN
        RAISE EXCEPTION USING ERRCODE = '22023';
    END IF;
    IF base_version IS NULL THEN
        INSERT INTO app.outfits(id,user_id,name,favorite)
        VALUES (outfit_id,owner_id,btrim(body->>'name'),(body->>'favorite')::boolean)
        RETURNING * INTO outfit;
    ELSE
        UPDATE app.outfits o SET name = btrim(body->>'name'), favorite = (body->>'favorite')::boolean
        WHERE o.id = outfit_id AND o.user_id = owner_id AND o.version = base_version AND o.deleted_at IS NULL
        RETURNING * INTO outfit;
        IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE = 'P0002'; END IF;
    END IF;
    -- Historical wear_event_items are intentionally never touched.
    DELETE FROM app.outfit_items i WHERE i.user_id = owner_id AND i.outfit_id = outfit.id;
    INSERT INTO app.outfit_items(user_id,outfit_id,garment_id,position)
        SELECT owner_id,outfit.id,value::uuid,ordinality - 1
        FROM jsonb_array_elements_text(body->'garmentIDs') WITH ORDINALITY;
    result := jsonb_build_object('data',api_private.outfit_item(outfit),'request_id',request_id);
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

REVOKE ALL ON FUNCTION app.api_v1_list_outfits(jsonb), app.api_v1_save_outfit(jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION app.api_v1_list_outfits(jsonb), app.api_v1_save_outfit(jsonb) TO authenticated;
