-- Explicit undo may restore only the acknowledged wear tombstone unchanged.
-- Old edits remain fenced by both version and deleted_at in save_wear.
CREATE FUNCTION api_private.touch_wear_history() RETURNS trigger LANGUAGE plpgsql
SET search_path=pg_catalog AS $$
BEGIN
 IF NEW.id IS DISTINCT FROM OLD.id OR NEW.user_id IS DISTINCT FROM OLD.user_id THEN
  RAISE EXCEPTION 'immutable identity' USING ERRCODE='23514';
 END IF;
 IF OLD.deleted_at IS NOT NULL AND NEW IS DISTINCT FROM OLD AND NOT (
  (NEW.deleted_at IS NULL AND to_jsonb(NEW)-'deleted_at'=to_jsonb(OLD)-'deleted_at') OR
  (pg_trigger_depth()>1 AND NEW.source_outfit_id IS NULL AND
   to_jsonb(NEW)-'source_outfit_id'=to_jsonb(OLD)-'source_outfit_id')
 ) THEN RAISE EXCEPTION 'tombstone cannot be edited' USING ERRCODE='23514'; END IF;
 NEW.created_at:=OLD.created_at; NEW.updated_at:=clock_timestamp(); NEW.version:=OLD.version+1;
 RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION api_private.touch_wear_history() FROM PUBLIC,anon,authenticated;
DROP TRIGGER touch_record ON app.wear_events;
CREATE TRIGGER touch_record BEFORE UPDATE ON app.wear_events FOR EACH ROW EXECUTE FUNCTION api_private.touch_wear_history();

CREATE FUNCTION app.api_v1_wear_visibility(request jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE owner_id uuid:=auth.uid(); request_id uuid:=gen_random_uuid(); operation uuid; target uuid;
 base bigint; action text:=request->>'action'; previous api_private.mutations%ROWTYPE;
 event app.wear_events%ROWTYPE; ids uuid[]; garment uuid; result jsonb;
BEGIN
 IF owner_id IS NULL THEN RETURN jsonb_build_object('error',jsonb_build_object('code','unauthorized','message','Sign in required','request_id',request_id)); END IF;
 PERFORM 1 FROM app.profiles WHERE user_id=owner_id AND deleted_at IS NULL FOR SHARE;
 IF NOT FOUND THEN RETURN jsonb_build_object('error',jsonb_build_object('code','account_unavailable','message','Account unavailable','request_id',request_id)); END IF;
 IF jsonb_typeof(request) IS DISTINCT FROM 'object' OR NOT request ?& ARRAY['operationID','id','baseVersion','action']
 OR request-ARRAY['operationID','id','baseVersion','action']<>'{}'
 OR action IS NULL OR action NOT IN ('remove','restore')
 OR jsonb_typeof(request->'baseVersion') IS DISTINCT FROM 'number' OR coalesce(request->>'baseVersion','') !~ '^[1-9][0-9]*$'
 THEN RAISE EXCEPTION USING ERRCODE='22023'; END IF;
 operation:=(request->>'operationID')::uuid; target:=(request->>'id')::uuid; base:=(request->>'baseVersion')::bigint;
 IF operation IS NULL OR target IS NULL THEN RAISE EXCEPTION USING ERRCODE='22023'; END IF;
 INSERT INTO api_private.mutations VALUES(owner_id,operation,request,NULL) ON CONFLICT DO NOTHING;
 SELECT * INTO previous FROM api_private.mutations m WHERE m.user_id=owner_id AND m.operation_id=operation FOR UPDATE;
 IF previous.request<>request THEN RETURN jsonb_build_object('error',jsonb_build_object('code','idempotency_conflict','message','Operation already used','request_id',request_id)); END IF;
 IF previous.response IS NOT NULL THEN RETURN previous.response; END IF;
 -- Match save_wear's garment-before-event ordering. Recheck membership after
 -- the event lock, since an edit may have committed while acquiring locks.
 SELECT array_agg(i.garment_id ORDER BY i.garment_id) INTO ids FROM app.wear_event_items i WHERE i.user_id=owner_id AND i.wear_event_id=target AND i.deleted_at IS NULL;
 FOREACH garment IN ARRAY coalesce(ids,ARRAY[]::uuid[]) LOOP
  PERFORM 1 FROM app.garments g WHERE g.user_id=owner_id AND g.id=garment FOR SHARE;
 END LOOP;
 SELECT * INTO event FROM app.wear_events w WHERE w.user_id=owner_id AND w.id=target FOR UPDATE;
 IF NOT FOUND OR event.version<>base OR (action='restore') IS DISTINCT FROM (event.deleted_at IS NOT NULL) THEN RAISE EXCEPTION USING ERRCODE='P0002'; END IF;
 IF action='restore' AND (coalesce(cardinality(ids),0)=0 OR EXISTS(
  SELECT FROM app.wear_event_items i LEFT JOIN app.garments g ON g.user_id=i.user_id AND g.id=i.garment_id
  WHERE i.user_id=owner_id AND i.wear_event_id=target AND i.deleted_at IS NULL AND (g.id IS NULL OR g.deleted_at IS NOT NULL)
 )) THEN RAISE EXCEPTION USING ERRCODE='22023'; END IF;
 UPDATE app.wear_events SET deleted_at=CASE WHEN action='remove' THEN clock_timestamp() ELSE NULL END
 WHERE id=target RETURNING * INTO event;
 SELECT coalesce(array_agg(i.garment_id ORDER BY i.garment_id),ARRAY[]::uuid[]) INTO ids FROM app.wear_event_items i WHERE i.user_id=owner_id AND i.wear_event_id=target AND i.deleted_at IS NULL;
 result:=jsonb_build_object('data',jsonb_build_object('id',event.id,'version',event.version,'deleted',event.deleted_at IS NOT NULL,
 'wornOn',to_char(event.worn_on,'YYYY-MM-DD'),'timezone',event.timezone,'garmentIDs',to_jsonb(ids)),'request_id',request_id);
 UPDATE api_private.mutations m SET response=result WHERE m.user_id=owner_id AND m.operation_id=operation;
 RETURN result;
EXCEPTION WHEN invalid_text_representation OR numeric_value_out_of_range OR invalid_parameter_value OR check_violation THEN
 RETURN jsonb_build_object('error',jsonb_build_object('code','validation_failed','message','Invalid history change','request_id',request_id));
 WHEN no_data_found THEN RETURN jsonb_build_object('error',jsonb_build_object('code','version_conflict','message','History changed; reload','request_id',request_id));
END $$;
REVOKE ALL ON FUNCTION app.api_v1_wear_visibility(jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION app.api_v1_wear_visibility(jsonb) TO authenticated;
