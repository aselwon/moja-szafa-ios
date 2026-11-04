-- Travel plans and packing checkmarks never write wear history.
ALTER TABLE app.trips ADD COLUMN max_items integer NOT NULL DEFAULT 20 CHECK(max_items BETWEEN 1 AND 100);
ALTER TABLE app.trips ADD COLUMN timezone text NOT NULL DEFAULT 'UTC';
ALTER TABLE app.trips ADD COLUMN days jsonb NOT NULL DEFAULT '[]' CHECK(jsonb_typeof(days)='array');

CREATE FUNCTION api_private.trip_day(owner_id uuid, day jsonb, all_days jsonb) RETURNS jsonb
LANGUAGE sql STABLE SET search_path=pg_catalog AS $$
WITH selected AS (
 SELECT value::uuid AS id FROM jsonb_array_elements_text(day->'garmentIDs')
), live AS (
 SELECT g.* FROM app.garments g JOIN selected s ON s.id=g.id WHERE g.user_id=owner_id AND g.deleted_at IS NULL
), available AS (
 SELECT * FROM live WHERE availability='available' AND archived_at IS NULL
), missing AS (
 SELECT CASE WHEN EXISTS(SELECT FROM available WHERE category IN ('dress','jumpsuit')) THEN '[]'::jsonb ELSE
    (CASE WHEN EXISTS(SELECT FROM available WHERE category='top') THEN '[]'::jsonb ELSE '["top"]'::jsonb END) ||
    (CASE WHEN EXISTS(SELECT FROM available WHERE category='bottom') THEN '[]'::jsonb ELSE '["bottom"]'::jsonb END) END ||
    (CASE WHEN EXISTS(SELECT FROM available WHERE category='shoes') THEN '[]'::jsonb ELSE '["shoes"]'::jsonb END) AS categories
)
SELECT day - 'garmentIDs' || jsonb_build_object(
 'garments',coalesce((SELECT jsonb_agg(api_private.wardrobe_item(g::app.garments) ORDER BY g.id) FROM live g),'[]'),
 'missingCategories',(SELECT categories FROM missing),
 'unavailableIDs',coalesce((SELECT jsonb_agg(s.id ORDER BY s.id) FROM selected s WHERE NOT EXISTS(SELECT FROM available a WHERE a.id=s.id)),'[]'),
 'repeated',EXISTS(SELECT FROM selected s JOIN jsonb_array_elements(all_days) other ON other->>'day'<>day->>'day'
    WHERE other->'garmentIDs' @> to_jsonb(ARRAY[s.id])));
$$;
REVOKE ALL ON FUNCTION api_private.trip_day(uuid,jsonb,jsonb) FROM PUBLIC,anon,authenticated;

CREATE FUNCTION api_private.trip_item(t app.trips) RETURNS jsonb
LANGUAGE sql STABLE SET search_path=pg_catalog AS $$
SELECT jsonb_build_object('id',t.id,'version',t.version,'destination',t.destination,'startsOn',to_char(t.starts_on,'YYYY-MM-DD'),
 'endsOn',to_char(t.ends_on,'YYYY-MM-DD'),'timezone',t.timezone,'occasions',to_jsonb(t.occasions),'maxItems',t.max_items,
 'days',coalesce((SELECT jsonb_agg(api_private.trip_day(t.user_id,d,t.days) ORDER BY d->>'day') FROM jsonb_array_elements(t.days) d),'[]'),
 'packing',coalesce((SELECT jsonb_agg(jsonb_build_object('garment',api_private.wardrobe_item(g),'packed',i.packed) ORDER BY g.id)
   FROM app.trip_items i JOIN app.garments g ON g.user_id=i.user_id AND g.id=i.garment_id
   WHERE i.user_id=t.user_id AND i.trip_id=t.id AND i.deleted_at IS NULL AND g.deleted_at IS NULL),'[]'));
$$;
REVOKE ALL ON FUNCTION api_private.trip_item(app.trips) FROM PUBLIC,anon,authenticated;

CREATE FUNCTION app.api_v1_trips(request jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE
 owner_id uuid:=auth.uid(); request_id uuid:=gen_random_uuid(); action text:=request->>'action';
 target uuid; operation uuid; base bigint; previous api_private.mutations%ROWTYPE; trip app.trips%ROWTYPE;
 result jsonb; rows jsonb; after_id uuid; next_cursor uuid;
 body jsonb; d jsonb; snapshot jsonb:='[]'; outfit app.outfits%ROWTYPE; ids uuid[]; all_ids uuid[]:='{}';
 first_day date; last_day date; days_seen date[]:='{}'; selected_day date; v_occasions text[]; maximum integer; garment uuid;
BEGIN
 IF owner_id IS NULL THEN RETURN jsonb_build_object('error',jsonb_build_object('code','unauthorized','message','Sign in required','request_id',request_id)); END IF;
 PERFORM 1 FROM app.profiles WHERE user_id=owner_id AND deleted_at IS NULL FOR SHARE;
 IF NOT FOUND THEN RETURN jsonb_build_object('error',jsonb_build_object('code','account_unavailable','message','Account unavailable','request_id',request_id)); END IF;
 IF jsonb_typeof(request) IS DISTINCT FROM 'object' OR action IS NULL OR action NOT IN ('list','get','save','pack') THEN RAISE EXCEPTION USING ERRCODE='22023'; END IF;
 IF action='list' THEN
  IF request-ARRAY['action','cursor']<>'{}' THEN RAISE EXCEPTION USING ERRCODE='22023'; END IF;
  after_id:=(request->>'cursor')::uuid;
  SELECT coalesce(jsonb_agg(jsonb_build_object('id',t.id,'destination',t.destination,'startsOn',to_char(t.starts_on,'YYYY-MM-DD'),'endsOn',to_char(t.ends_on,'YYYY-MM-DD')) ORDER BY t.id),'[]') INTO rows
    FROM (SELECT * FROM app.trips WHERE user_id=owner_id AND deleted_at IS NULL AND (after_id IS NULL OR id>after_id) ORDER BY id LIMIT 21) t;
  IF jsonb_array_length(rows)>20 THEN rows:=rows-20; next_cursor:=(rows->19->>'id')::uuid; END IF;
  RETURN jsonb_build_object('data',jsonb_build_object('items',rows,'nextCursor',next_cursor),'request_id',request_id);
 END IF;
 target:=(request->>'id')::uuid;
 IF target IS NULL THEN RAISE EXCEPTION USING ERRCODE='22023'; END IF;
 IF action='get' THEN
  IF request-ARRAY['action','id']<>'{}' THEN RAISE EXCEPTION USING ERRCODE='22023'; END IF;
  SELECT * INTO trip FROM app.trips WHERE id=target AND user_id=owner_id AND deleted_at IS NULL;
  IF NOT FOUND THEN RETURN jsonb_build_object('error',jsonb_build_object('code','not_found','message','Trip unavailable','request_id',request_id)); END IF;
  RETURN jsonb_build_object('data',api_private.trip_item(trip),'request_id',request_id);
 END IF;
 IF NOT request ?& ARRAY['action','id','operationID','baseVersion'] OR jsonb_typeof(request->'baseVersion') IS DISTINCT FROM 'number'
  OR coalesce(request->>'baseVersion','') !~ '^[0-9]+$' THEN RAISE EXCEPTION USING ERRCODE='22023'; END IF;
 operation:=(request->>'operationID')::uuid; base:=(request->>'baseVersion')::bigint;
 IF operation IS NULL THEN RAISE EXCEPTION USING ERRCODE='22023'; END IF;
 INSERT INTO api_private.mutations VALUES(owner_id,operation,request,NULL) ON CONFLICT DO NOTHING;
 SELECT * INTO previous FROM api_private.mutations m WHERE m.user_id=owner_id AND m.operation_id=operation FOR UPDATE;
 IF previous.request<>request THEN RETURN jsonb_build_object('error',jsonb_build_object('code','idempotency_conflict','message','Operation already used','request_id',request_id)); END IF;
 IF previous.response IS NOT NULL THEN RETURN previous.response; END IF;
 IF action='pack' THEN
  IF NOT request ?& ARRAY['garmentID','packed'] OR request-ARRAY['action','id','operationID','baseVersion','garmentID','packed']<>'{}'
   OR jsonb_typeof(request->'packed') IS DISTINCT FROM 'boolean' THEN RAISE EXCEPTION USING ERRCODE='22023'; END IF;
  garment:=(request->>'garmentID')::uuid;
  PERFORM 1 FROM app.garments g WHERE g.user_id=owner_id AND g.id=garment AND g.deleted_at IS NULL
    AND ((request->>'packed')::boolean=false OR (g.availability='available' AND g.archived_at IS NULL)) FOR SHARE;
  IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='22023'; END IF;
  UPDATE app.trips t SET destination=t.destination WHERE t.id=target AND t.user_id=owner_id AND t.version=base AND t.deleted_at IS NULL RETURNING * INTO trip;
  IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='P0002'; END IF;
  UPDATE app.trip_items SET packed=(request->>'packed')::boolean WHERE user_id=owner_id AND trip_id=target AND garment_id=garment AND deleted_at IS NULL;
  IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='22023'; END IF;
 ELSE
  IF NOT request ? 'trip' OR request-ARRAY['action','id','operationID','baseVersion','trip']<>'{}' THEN RAISE EXCEPTION USING ERRCODE='22023'; END IF;
  body:=request->'trip';
  IF jsonb_typeof(body) IS DISTINCT FROM 'object' OR NOT body ?& ARRAY['destination','startsOn','endsOn','timezone','occasions','maxItems','days']
   OR body-ARRAY['destination','startsOn','endsOn','timezone','occasions','maxItems','days']<>'{}'
   OR jsonb_typeof(body->'destination') IS DISTINCT FROM 'string' OR length(btrim(body->>'destination')) NOT BETWEEN 1 AND 200
   OR coalesce(body->>'startsOn','') !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' OR coalesce(body->>'endsOn','') !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
   OR NOT EXISTS(SELECT FROM pg_timezone_names WHERE name=body->>'timezone')
   OR jsonb_typeof(body->'occasions') IS DISTINCT FROM 'array' OR jsonb_typeof(body->'days') IS DISTINCT FROM 'array'
   OR jsonb_typeof(body->'maxItems') IS DISTINCT FROM 'number' OR coalesce(body->>'maxItems','') !~ '^[1-9][0-9]*$'
  THEN RAISE EXCEPTION USING ERRCODE='22023'; END IF;
  first_day:=(body->>'startsOn')::date; last_day:=(body->>'endsOn')::date; maximum:=(body->>'maxItems')::integer;
  IF last_day-first_day NOT BETWEEN 0 AND 29 OR maximum NOT BETWEEN 1 AND 100 OR jsonb_array_length(body->'occasions') NOT BETWEEN 1 AND 10
   OR EXISTS(SELECT FROM jsonb_array_elements(body->'occasions') x WHERE jsonb_typeof(x)<>'string' OR length(btrim(x#>>'{}')) NOT BETWEEN 1 AND 80)
   OR jsonb_array_length(body->'days')<>last_day-first_day+1 THEN RAISE EXCEPTION USING ERRCODE='22023'; END IF;
  SELECT array_agg(btrim(value)) INTO v_occasions FROM jsonb_array_elements_text(body->'occasions');
  -- Lock selected outfit rows in stable order before reading their membership.
  PERFORM o.id FROM app.outfits o WHERE o.user_id=owner_id AND o.id IN
    (SELECT (v->>'outfitID')::uuid FROM jsonb_array_elements(body->'days') v) ORDER BY o.id FOR SHARE;
  FOR d IN SELECT value FROM jsonb_array_elements(body->'days') LOOP
   IF jsonb_typeof(d) IS DISTINCT FROM 'object' OR NOT d ?& ARRAY['day','outfitID','outfitVersion'] OR d-ARRAY['day','outfitID','outfitVersion']<>'{}'
    OR coalesce(d->>'day','') !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' THEN RAISE EXCEPTION USING ERRCODE='22023'; END IF;
   selected_day:=(d->>'day')::date;
   IF selected_day<first_day OR selected_day>last_day OR selected_day=ANY(days_seen) THEN RAISE EXCEPTION USING ERRCODE='22023'; END IF;
   days_seen:=array_append(days_seen,selected_day); ids:='{}'; outfit:=NULL;
   IF d->'outfitID'<>'null' THEN
    IF jsonb_typeof(d->'outfitVersion') IS DISTINCT FROM 'number' OR coalesce(d->>'outfitVersion','') !~ '^[1-9][0-9]*$' THEN RAISE EXCEPTION USING ERRCODE='22023'; END IF;
    SELECT * INTO outfit FROM app.outfits o WHERE o.user_id=owner_id AND o.id=(d->>'outfitID')::uuid AND o.version=(d->>'outfitVersion')::bigint AND o.deleted_at IS NULL;
    IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='P0002'; END IF;
    SELECT coalesce(array_agg(i.garment_id ORDER BY i.garment_id),'{}') INTO ids FROM app.outfit_items i WHERE i.user_id=owner_id AND i.outfit_id=outfit.id AND i.deleted_at IS NULL;
    IF cardinality(ids) NOT BETWEEN 1 AND 100 THEN RAISE EXCEPTION USING ERRCODE='22023'; END IF;
   ELSIF d->'outfitVersion'<>'null' THEN RAISE EXCEPTION USING ERRCODE='22023'; END IF;
   all_ids:=all_ids||ids;
   snapshot:=snapshot||jsonb_build_array(jsonb_build_object('day',selected_day::text,'outfitID',outfit.id,'outfitVersion',outfit.version,'outfitName',outfit.name,'garmentIDs',to_jsonb(ids)));
  END LOOP;
  SELECT coalesce(array_agg(DISTINCT id ORDER BY id),'{}') INTO all_ids FROM unnest(all_ids) id;
  IF cardinality(all_ids)>maximum THEN RAISE EXCEPTION USING ERRCODE='22023'; END IF;
  PERFORM g.id FROM app.garments g WHERE g.user_id=owner_id AND g.id=ANY(all_ids) AND g.deleted_at IS NULL AND g.archived_at IS NULL AND g.availability='available' ORDER BY g.id FOR SHARE;
  IF (SELECT count(*) FROM app.garments g WHERE g.user_id=owner_id AND g.id=ANY(all_ids) AND g.deleted_at IS NULL AND g.archived_at IS NULL AND g.availability='available')<>cardinality(all_ids) THEN RAISE EXCEPTION USING ERRCODE='22023'; END IF;
  IF base=0 THEN
   INSERT INTO app.trips(id,user_id,destination,starts_on,ends_on,timezone,occasions,max_items,days)
    VALUES(target,owner_id,btrim(body->>'destination'),first_day,last_day,body->>'timezone',v_occasions,maximum,snapshot) RETURNING * INTO trip;
  ELSE
   UPDATE app.trips t SET destination=btrim(body->>'destination'),starts_on=first_day,ends_on=last_day,timezone=body->>'timezone',occasions=v_occasions,max_items=maximum,days=snapshot
    WHERE t.user_id=owner_id AND t.id=target AND t.version=base AND t.deleted_at IS NULL RETURNING * INTO trip;
   IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='P0002'; END IF;
  END IF;
  DELETE FROM app.trip_items WHERE user_id=owner_id AND trip_id=target AND NOT(garment_id=ANY(all_ids));
  INSERT INTO app.trip_items(user_id,trip_id,garment_id) SELECT owner_id,target,id FROM unnest(all_ids) id ON CONFLICT(user_id,trip_id,garment_id) DO NOTHING;
 END IF;
 result:=jsonb_build_object('data',api_private.trip_item(trip),'request_id',request_id);
 UPDATE api_private.mutations m SET response=result WHERE m.user_id=owner_id AND m.operation_id=operation;
 RETURN result;
EXCEPTION
 WHEN invalid_text_representation OR invalid_parameter_value OR numeric_value_out_of_range OR invalid_datetime_format OR datetime_field_overflow OR check_violation OR foreign_key_violation OR not_null_violation THEN
  RETURN jsonb_build_object('error',jsonb_build_object('code','validation_failed','message','Invalid trip, item limit or unavailable garments','request_id',request_id));
 WHEN unique_violation OR no_data_found THEN
  RETURN jsonb_build_object('error',jsonb_build_object('code','version_conflict','message','Trip or outfit changed; reload before editing','request_id',request_id));
END $$;
REVOKE ALL ON FUNCTION app.api_v1_trips(jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION app.api_v1_trips(jsonb) TO authenticated;

-- Preserve earlier feature export projections and add only owned travel fields.
ALTER FUNCTION api_private.export_snapshot(uuid) RENAME TO export_snapshot_pre021;
CREATE FUNCTION api_private.export_snapshot(owner_id uuid) RETURNS jsonb
LANGUAGE sql STABLE SET search_path=pg_catalog AS $$
 SELECT api_private.export_snapshot_pre021(owner_id) || jsonb_build_object('trips',
  (SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY r.id),'[]') FROM
   (SELECT id,destination,starts_on,ends_on,occasions,max_items,timezone,days FROM app.trips
    WHERE user_id=owner_id AND deleted_at IS NULL) r));
$$;
REVOKE ALL ON FUNCTION api_private.export_snapshot(uuid) FROM PUBLIC,anon,authenticated;
