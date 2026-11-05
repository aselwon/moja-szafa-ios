-- Persist all import form attributes atomically with the idempotent garment write.
-- Older clients omit metadata; their status edits preserve these attributes.
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
       OR body - ARRAY['name','category','price_grosz','availability','archived','metadata'] <> '{}'::jsonb
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
    IF body ? 'metadata' THEN
        IF jsonb_typeof(body->'metadata') IS DISTINCT FROM 'object'
           OR NOT (body->'metadata') ?& ARRAY['colors','seasons','pattern','formality','brand','purchased_on']
           OR (body->'metadata') - ARRAY['colors','seasons','pattern','formality','brand','purchased_on'] <> '{}'::jsonb
           OR jsonb_typeof(body->'metadata'->'colors') IS DISTINCT FROM 'array'
           OR jsonb_typeof(body->'metadata'->'seasons') IS DISTINCT FROM 'array' THEN
            RAISE EXCEPTION USING ERRCODE = '22023';
        END IF;
        IF EXISTS (SELECT 1 FROM jsonb_array_elements(body->'metadata'->'colors') c
                   WHERE jsonb_typeof(c) <> 'string' OR c #>> '{}' NOT IN
                   ('black','white','gray','beige','brown','red','orange','yellow','green','blue','purple','pink','other'))
           OR EXISTS (SELECT 1 FROM jsonb_array_elements(body->'metadata'->'seasons') s
                   WHERE jsonb_typeof(s) <> 'string' OR s #>> '{}' NOT IN ('spring','summer','autumn','winter'))
           OR (SELECT count(*) <> count(DISTINCT c) FROM jsonb_array_elements(body->'metadata'->'colors') c)
           OR (SELECT count(*) <> count(DISTINCT s) FROM jsonb_array_elements(body->'metadata'->'seasons') s)
           OR EXISTS (SELECT 1 FROM jsonb_each(body->'metadata') e WHERE e.key IN ('pattern','brand')
                      AND e.value <> 'null'::jsonb AND (jsonb_typeof(e.value) <> 'string' OR length(e.value #>> '{}') > 200))
           OR (body->'metadata'->'formality' <> 'null'::jsonb AND
               (jsonb_typeof(body->'metadata'->'formality') <> 'number' OR
                (body->'metadata'->>'formality') !~ '^[1-5]$'))
           OR (body->'metadata'->'purchased_on' <> 'null'::jsonb AND
               (jsonb_typeof(body->'metadata'->'purchased_on') <> 'string' OR
                (body->'metadata'->>'purchased_on') !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$')) THEN
            RAISE EXCEPTION USING ERRCODE = '22023';
        END IF;
        IF (body->'metadata'->>'purchased_on')::date > (now() AT TIME ZONE 'Pacific/Kiritimati')::date THEN
            RAISE EXCEPTION USING ERRCODE = '22023';
        END IF;
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
        INSERT INTO app.garments(id,user_id,name,category,price_grosz,availability,archived_at,colors,seasons,pattern,formality,brand,purchased_on)
        VALUES (garment_id,owner_id,body->>'name',body->>'category',(body->>'price_grosz')::bigint,body->>'availability',CASE WHEN (body->>'archived')::boolean THEN now() ELSE NULL END,
            ARRAY(SELECT jsonb_array_elements_text(body->'metadata'->'colors')),
            ARRAY(SELECT jsonb_array_elements_text(body->'metadata'->'seasons')),
            body->'metadata'->>'pattern',(body->'metadata'->>'formality')::smallint,
            body->'metadata'->>'brand',(body->'metadata'->>'purchased_on')::date)
        RETURNING * INTO garment;
    ELSE
        UPDATE app.garments g SET name = body->>'name', category = body->>'category',
            price_grosz = (body->>'price_grosz')::bigint, availability = body->>'availability',
            archived_at = CASE WHEN NOT body ? 'archived' THEN g.archived_at
                WHEN (body->>'archived')::boolean THEN coalesce(g.archived_at,now()) ELSE NULL END,
            colors = CASE WHEN body ? 'metadata' THEN ARRAY(SELECT jsonb_array_elements_text(body->'metadata'->'colors')) ELSE g.colors END,
            seasons = CASE WHEN body ? 'metadata' THEN ARRAY(SELECT jsonb_array_elements_text(body->'metadata'->'seasons')) ELSE g.seasons END,
            pattern = CASE WHEN body ? 'metadata' THEN body->'metadata'->>'pattern' ELSE g.pattern END,
            formality = CASE WHEN body ? 'metadata' THEN (body->'metadata'->>'formality')::smallint ELSE g.formality END,
            brand = CASE WHEN body ? 'metadata' THEN body->'metadata'->>'brand' ELSE g.brand END,
            purchased_on = CASE WHEN body ? 'metadata' THEN (body->'metadata'->>'purchased_on')::date ELSE g.purchased_on END
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
    WHEN invalid_datetime_format OR datetime_field_overflow OR invalid_text_representation OR numeric_value_out_of_range OR invalid_parameter_value OR check_violation THEN
        RETURN jsonb_build_object('error',jsonb_build_object('code','validation_failed','message','Invalid request','request_id',request_id));
    WHEN unique_violation OR no_data_found THEN
        RETURN jsonb_build_object('error',jsonb_build_object('code','version_conflict','message','Record changed or unavailable','request_id',request_id));
    WHEN OTHERS THEN
        RETURN jsonb_build_object('error',jsonb_build_object('code','internal_error','message','Request could not be completed','request_id',request_id));
END $$;

