-- Read-only browse/detail contracts. No original bytes, object keys or signed
-- URLs in list responses. The thumbnail capability is requested only on display.
CREATE FUNCTION api_private.wardrobe_item(g app.garments) RETURNS jsonb
LANGUAGE sql STABLE SET search_path = pg_catalog AS $$
    SELECT jsonb_build_object('id',g.id,'name',g.name,'category',g.category,
        'availability',g.availability,'priceGrosz',g.price_grosz,'brand',g.brand,
        'colors',g.colors,'seasons',g.seasons,'archived',g.archived_at IS NOT NULL,
        'imageID',(SELECT u.id FROM api_private.image_uploads u
            JOIN app.garment_images i ON i.user_id = u.user_id AND i.garment_id = u.garment_id
                AND i.object_key = u.id::text || '/thumbnail.jpg'
            WHERE u.user_id = g.user_id AND u.garment_id = g.id AND u.state = 'ready'
                AND i.variant = 'thumbnail' AND i.status = 'ready' AND i.deleted_at IS NULL
            ORDER BY u.id LIMIT 1));
$$;
REVOKE ALL ON FUNCTION api_private.wardrobe_item(app.garments) FROM PUBLIC, anon, authenticated;

CREATE FUNCTION app.api_v1_browse_wardrobe(request jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
DECLARE
    owner_id uuid := auth.uid();
    request_id uuid := gen_random_uuid();
    q jsonb := request->'query';
    page_limit integer;
    page_offset integer;
    rows jsonb;
    next_offset integer;
BEGIN
    IF owner_id IS NULL THEN
        RETURN jsonb_build_object('error',jsonb_build_object('code','unauthorized','message','Sign in required','request_id',request_id));
    END IF;
    IF NOT EXISTS (SELECT FROM app.profiles WHERE user_id = owner_id AND deleted_at IS NULL) THEN
        RETURN jsonb_build_object('error',jsonb_build_object('code','account_unavailable','message','Account unavailable','request_id',request_id));
    END IF;
    page_limit := (request->>'limit')::integer;
    page_offset := (request->>'offset')::integer;
    IF jsonb_typeof(request) IS DISTINCT FROM 'object'
        OR NOT request ?& ARRAY['query','offset','limit'] OR request - ARRAY['query','offset','limit'] <> '{}'
        OR jsonb_typeof(q) IS DISTINCT FROM 'object'
        OR NOT q ?& ARRAY['search','sort','archived']
        OR q - ARRAY['search','sort','archived','category','availability'] <> '{}'
        OR jsonb_typeof(q->'search') IS DISTINCT FROM 'string' OR length(q->>'search') > 200
        OR jsonb_typeof(q->'archived') IS DISTINCT FROM 'boolean'
        OR q->>'sort' IS NULL OR q->>'sort' NOT IN ('name','nameDescending','price')
        OR (q->>'category' IS NOT NULL AND q->>'category' NOT IN ('top','bottom','shoes','dress','jumpsuit','outerwear','accessory','other'))
        OR (q->>'availability' IS NOT NULL AND q->>'availability' NOT IN ('available','laundry','unavailable'))
        OR page_limit IS NULL OR page_limit NOT BETWEEN 1 AND 100
        OR page_offset IS NULL OR page_offset NOT BETWEEN 0 AND 1000000
        OR jsonb_typeof(request->'limit') IS DISTINCT FROM 'number'
        OR jsonb_typeof(request->'offset') IS DISTINCT FROM 'number'
        OR request->>'limit' !~ '^[0-9]+$' OR request->>'offset' !~ '^[0-9]+$'
    THEN RAISE EXCEPTION USING ERRCODE = '22023'; END IF;
    SELECT coalesce(jsonb_agg(item ORDER BY position),'[]'::jsonb) INTO rows FROM (
        SELECT api_private.wardrobe_item(g) AS item,
            row_number() OVER (ORDER BY
                CASE WHEN q->>'sort' = 'price' THEN g.price_grosz END ASC NULLS LAST,
                CASE WHEN q->>'sort' = 'nameDescending' THEN lower(g.name) END DESC,
                CASE WHEN q->>'sort' <> 'nameDescending' THEN lower(g.name) END ASC, g.id) AS position
        FROM app.garments g
        WHERE g.user_id = owner_id AND g.deleted_at IS NULL
            AND (g.archived_at IS NOT NULL) = (q->>'archived')::boolean
            AND (q->>'category' IS NULL OR g.category = q->>'category')
            AND (q->>'availability' IS NULL OR g.availability = q->>'availability')
            -- Literal substring search: %, _ and backslash are not wildcards.
            AND (strpos(lower(g.name),lower(q->>'search')) > 0 OR strpos(lower(coalesce(g.brand,'')),lower(q->>'search')) > 0)
        ORDER BY position LIMIT page_limit + 1 OFFSET page_offset
    ) page;
    IF jsonb_array_length(rows) > page_limit THEN
        rows := rows - page_limit;
        next_offset := page_offset + page_limit;
    END IF;
    RETURN jsonb_build_object('data',jsonb_build_object('items',rows,'nextOffset',next_offset,'cached',false),'request_id',request_id);
EXCEPTION WHEN invalid_text_representation OR numeric_value_out_of_range OR invalid_parameter_value THEN
    RETURN jsonb_build_object('error',jsonb_build_object('code','validation_failed','message','Invalid query','request_id',request_id));
END $$;

CREATE FUNCTION app.api_v1_garment_detail(request jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
DECLARE
    owner_id uuid := auth.uid();
    request_id uuid := gen_random_uuid();
    garment app.garments%ROWTYPE;
    days jsonb;
BEGIN
    IF jsonb_typeof(request) IS DISTINCT FROM 'object' OR NOT request ? 'id' OR request - 'id' <> '{}' THEN
        RAISE EXCEPTION USING ERRCODE = '22023';
    END IF;
    SELECT g.* INTO garment FROM app.garments g JOIN app.profiles p ON p.user_id = g.user_id
    WHERE g.id = (request->>'id')::uuid AND g.user_id = owner_id AND g.deleted_at IS NULL AND p.deleted_at IS NULL;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('error',jsonb_build_object('code','not_found','message','Garment unavailable','request_id',request_id));
    END IF;
    SELECT coalesce(jsonb_agg(worn_on ORDER BY worn_on DESC),'[]'::jsonb) INTO days FROM (
        SELECT DISTINCT e.worn_on FROM app.wear_events e JOIN app.wear_event_items i
            ON i.user_id = e.user_id AND i.wear_event_id = e.id
        WHERE e.user_id = owner_id AND i.garment_id = garment.id
            AND e.deleted_at IS NULL AND i.deleted_at IS NULL
    ) history;
    RETURN jsonb_build_object('data',jsonb_build_object('garment',api_private.wardrobe_item(garment),'wornOn',days,'cached',false),'request_id',request_id);
EXCEPTION WHEN invalid_text_representation OR invalid_parameter_value THEN
    RETURN jsonb_build_object('error',jsonb_build_object('code','validation_failed','message','Invalid garment','request_id',request_id));
END $$;
REVOKE ALL ON FUNCTION app.api_v1_browse_wardrobe(jsonb), app.api_v1_garment_detail(jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION app.api_v1_browse_wardrobe(jsonb), app.api_v1_garment_detail(jsonb) TO authenticated;
CREATE INDEX garments_browse_name ON app.garments(user_id,lower(name),id) WHERE deleted_at IS NULL;

-- Add optional display metadata without changing the outbox mutation format.
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

