-- T037: explicit estimates do not create or rewrite journal events.
CREATE OR REPLACE FUNCTION api_private.wardrobe_item(g app.garments) RETURNS jsonb
LANGUAGE sql STABLE SET search_path = pg_catalog AS $$
    SELECT jsonb_build_object('id',g.id,'name',g.name,'category',g.category,
        'initialWearHistory',CASE WHEN g.tracking_start_date IS NULL THEN NULL ELSE jsonb_build_object('count',g.estimated_prior_wears,'startDate',to_char(g.tracking_start_date,'YYYY-MM-DD')) END,
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

CREATE FUNCTION app.api_v1_initial_wear_history(request jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE owner_id uuid:=auth.uid(); request_id uuid:=gen_random_uuid(); operation uuid; target uuid;
 base bigint; prior integer; boundary date; history jsonb:=request->'history';
 previous api_private.mutations%ROWTYPE; garment app.garments%ROWTYPE; result jsonb;
BEGIN
 IF owner_id IS NULL THEN RETURN jsonb_build_object('error',jsonb_build_object('code','unauthorized','message','Sign in required','request_id',request_id)); END IF;
 PERFORM 1 FROM app.profiles WHERE user_id=owner_id AND deleted_at IS NULL FOR SHARE;
 IF NOT FOUND THEN RETURN jsonb_build_object('error',jsonb_build_object('code','account_unavailable','message','Account unavailable','request_id',request_id)); END IF;
 IF jsonb_typeof(request) IS DISTINCT FROM 'object' OR NOT request ?& ARRAY['operationID','id','baseVersion','history','confirmOverlap']
 OR request-ARRAY['operationID','id','baseVersion','history','confirmOverlap']<>'{}'
 OR jsonb_typeof(request->'baseVersion') IS DISTINCT FROM 'number' OR coalesce(request->>'baseVersion','') !~ '^[1-9][0-9]*$'
 OR jsonb_typeof(request->'confirmOverlap') IS DISTINCT FROM 'boolean' THEN RAISE EXCEPTION USING ERRCODE='22023'; END IF;
 IF history='null'::jsonb THEN prior:=0; boundary:=NULL;
 ELSE
  IF jsonb_typeof(history) IS DISTINCT FROM 'object' OR NOT history ?& ARRAY['count','startDate']
  OR history-ARRAY['count','startDate']<>'{}' OR jsonb_typeof(history->'count') IS DISTINCT FROM 'number'
  OR coalesce(history->>'count','') !~ '^[0-9]+$'
  OR jsonb_typeof(history->'startDate') IS DISTINCT FROM 'string'
  OR coalesce(history->>'startDate','') !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' THEN RAISE EXCEPTION USING ERRCODE='22023'; END IF;
  prior:=(history->>'count')::integer; boundary:=(history->>'startDate')::date;
  IF prior NOT BETWEEN 0 AND 1000000 OR to_char(boundary,'YYYY-MM-DD')<>history->>'startDate' THEN RAISE EXCEPTION USING ERRCODE='22023'; END IF;
 END IF;
 operation:=(request->>'operationID')::uuid; target:=(request->>'id')::uuid; base:=(request->>'baseVersion')::bigint;
 IF operation IS NULL OR target IS NULL THEN RAISE EXCEPTION USING ERRCODE='22023'; END IF;
 INSERT INTO api_private.mutations VALUES(owner_id,operation,request,NULL) ON CONFLICT DO NOTHING;
 SELECT * INTO previous FROM api_private.mutations m WHERE m.user_id=owner_id AND m.operation_id=operation FOR UPDATE;
 IF previous.request<>request THEN RETURN jsonb_build_object('error',jsonb_build_object('code','idempotency_conflict','message','Operation already used','request_id',request_id)); END IF;
 -- Garment lock serializes against new wear membership and permanent deletion.
 SELECT * INTO garment FROM app.garments g WHERE g.user_id=owner_id AND g.id=target AND g.deleted_at IS NULL FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='P0002'; END IF;
 -- A replay may acknowledge the old version, but must never return private
 -- metadata for a garment that has since been permanently deleted.
 IF previous.response IS NOT NULL THEN RETURN previous.response; END IF;
 IF garment.version<>base THEN RAISE EXCEPTION USING ERRCODE='P0002'; END IF;
 IF boundary IS DISTINCT FROM garment.tracking_start_date AND boundary IS NOT NULL
 AND NOT (request->>'confirmOverlap')::boolean AND EXISTS (
  SELECT FROM app.wear_events e JOIN app.wear_event_items i ON i.user_id=e.user_id AND i.wear_event_id=e.id
  WHERE e.user_id=owner_id AND i.garment_id=target AND e.deleted_at IS NULL AND i.deleted_at IS NULL AND e.worn_on<greatest(boundary,garment.tracking_start_date)
 ) THEN RAISE EXCEPTION 'Confirm overlapping history' USING ERRCODE='22023'; END IF;
 UPDATE app.garments SET estimated_prior_wears=prior,tracking_start_date=boundary WHERE id=target RETURNING * INTO garment;
 result:=jsonb_build_object('data',jsonb_build_object('id',garment.id,'version',garment.version,'deleted',false,
  'metadata',api_private.wardrobe_item(garment),'fields',jsonb_build_object('name',garment.name,'category',garment.category,
  'price_grosz',garment.price_grosz,'availability',garment.availability,'archived',garment.archived_at IS NOT NULL)), 'request_id',request_id);
 UPDATE api_private.mutations m SET response=result WHERE m.user_id=owner_id AND m.operation_id=operation;
 RETURN result;
EXCEPTION WHEN invalid_text_representation OR numeric_value_out_of_range OR invalid_parameter_value OR datetime_field_overflow OR check_violation THEN
 RETURN jsonb_build_object('error',jsonb_build_object('code','validation_failed','message','Invalid estimate or unconfirmed history overlap','request_id',request_id));
 WHEN no_data_found THEN RETURN jsonb_build_object('error',jsonb_build_object('code','version_conflict','message','Garment changed; reload','request_id',request_id));
END $$;
REVOKE ALL ON FUNCTION app.api_v1_initial_wear_history(jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION app.api_v1_initial_wear_history(jsonb) TO authenticated;
