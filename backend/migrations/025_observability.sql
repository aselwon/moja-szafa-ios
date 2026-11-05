-- T053: explicit, versioned telemetry choices and bounded owner-scoped diagnostics.
-- No public/operator grant is introduced here; operational reads remain owner-only.
CREATE TABLE api_private.telemetry_preferences (
 user_id uuid PRIMARY KEY REFERENCES app.profiles(user_id) ON DELETE CASCADE,
 version bigint NOT NULL DEFAULT 0 CHECK(version>=0),
 diagnostics boolean NOT NULL DEFAULT false, product boolean NOT NULL DEFAULT false,
 updated_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE TABLE api_private.telemetry_events (
 user_id uuid NOT NULL REFERENCES app.profiles(user_id) ON DELETE CASCADE,
 id uuid NOT NULL, received_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 kind text NOT NULL CHECK(kind IN('api','sync','crash','session','wardrobe_5','outfits_3')),
 data jsonb NOT NULL, PRIMARY KEY(user_id,id), CHECK(octet_length(data::text)<=12288)
);
CREATE INDEX telemetry_retention ON api_private.telemetry_events(received_at);
CREATE UNIQUE INDEX telemetry_activation_once ON api_private.telemetry_events(user_id,kind) WHERE kind IN('wardrobe_5','outfits_3');
CREATE TABLE api_private.telemetry_consent_changes (
 user_id uuid NOT NULL REFERENCES app.profiles(user_id) ON DELETE CASCADE,
 version bigint NOT NULL, diagnostics boolean NOT NULL, product boolean NOT NULL,
 changed_at timestamptz NOT NULL DEFAULT clock_timestamp(), PRIMARY KEY(user_id,version)
);
REVOKE ALL ON api_private.telemetry_preferences,api_private.telemetry_events,api_private.telemetry_consent_changes FROM PUBLIC,anon,authenticated,service_role;

CREATE FUNCTION api_private.telemetry_preferences_json(owner_id uuid) RETURNS jsonb
LANGUAGE sql STABLE SET search_path=pg_catalog AS $$
 SELECT coalesce((SELECT jsonb_build_object('version',version,'diagnostics',diagnostics,'product',product,'updatedAt',updated_at)
 FROM api_private.telemetry_preferences WHERE user_id=owner_id),jsonb_build_object('version',0,'diagnostics',false,'product',false,'updatedAt',NULL));
$$;
REVOKE ALL ON FUNCTION api_private.telemetry_preferences_json(uuid) FROM PUBLIC,anon,authenticated,service_role;

CREATE FUNCTION app.api_v1_telemetry(request jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE owner_id uuid:=auth.uid(); rid uuid:=gen_random_uuid(); action text:=request->>'action';
 prefs api_private.telemetry_preferences%ROWTYPE; operation uuid; previous api_private.mutations%ROWTYPE;
 base bigint; item jsonb; frame jsonb; event_id uuid; event_kind text; existing jsonb; result jsonb;
 count_today bigint; crashes_today bigint; accepted integer:=0; cutoff timestamptz:=clock_timestamp()-interval '30 days';
BEGIN
 IF owner_id IS NULL THEN RETURN jsonb_build_object('error',jsonb_build_object('code','unauthorized','message','Sign in required','request_id',rid)); END IF;
 -- Serializes ingest, consent withdrawal and account deletion. Old queued batches
 -- cannot cross a consent revision even when a device retries after a timeout.
 PERFORM 1 FROM app.profiles WHERE user_id=owner_id AND deleted_at IS NULL FOR UPDATE;
 IF NOT FOUND THEN RETURN jsonb_build_object('error',jsonb_build_object('code','account_unavailable','message','Account unavailable','request_id',rid)); END IF;
 IF jsonb_typeof(request) IS DISTINCT FROM 'object' OR action IS NULL OR action NOT IN('get','preferences','ingest') OR octet_length(request::text)>32768 THEN RAISE EXCEPTION USING ERRCODE='22023'; END IF;
 IF action='get' THEN
  IF request-ARRAY['action']<>'{}' THEN RAISE EXCEPTION USING ERRCODE='22023'; END IF;
  RETURN jsonb_build_object('data',api_private.telemetry_preferences_json(owner_id),'request_id',rid);
 END IF;
 INSERT INTO api_private.telemetry_preferences(user_id) VALUES(owner_id) ON CONFLICT DO NOTHING;
 SELECT * INTO prefs FROM api_private.telemetry_preferences WHERE user_id=owner_id;
 IF action='preferences' THEN
  IF NOT request ?& ARRAY['operationID','baseVersion','diagnostics','product'] OR request-ARRAY['action','operationID','baseVersion','diagnostics','product']<>'{}'
  OR jsonb_typeof(request->'diagnostics') IS DISTINCT FROM 'boolean' OR jsonb_typeof(request->'product') IS DISTINCT FROM 'boolean'
  OR jsonb_typeof(request->'baseVersion') IS DISTINCT FROM 'number' OR coalesce(request->>'baseVersion','')!~'^[0-9]+$' THEN RAISE EXCEPTION USING ERRCODE='22023'; END IF;
  operation:=(request->>'operationID')::uuid; base:=(request->>'baseVersion')::bigint;
  IF operation IS NULL THEN RAISE EXCEPTION USING ERRCODE='22023'; END IF;
  INSERT INTO api_private.mutations(user_id,operation_id,request,response) VALUES(owner_id,operation,request,NULL) ON CONFLICT DO NOTHING;
  SELECT * INTO previous FROM api_private.mutations WHERE user_id=owner_id AND operation_id=operation FOR UPDATE;
  IF previous.request<>request THEN RETURN jsonb_build_object('error',jsonb_build_object('code','idempotency_conflict','message','Operation already used','request_id',rid)); END IF;
  IF previous.response IS NOT NULL THEN RETURN previous.response; END IF;
  IF prefs.version<>base THEN RAISE EXCEPTION USING ERRCODE='P0002'; END IF;
  UPDATE api_private.telemetry_preferences SET version=version+1,diagnostics=(request->>'diagnostics')::boolean,
   product=(request->>'product')::boolean,updated_at=clock_timestamp() WHERE user_id=owner_id RETURNING * INTO prefs;
  INSERT INTO api_private.telemetry_consent_changes(user_id,version,diagnostics,product) VALUES(owner_id,prefs.version,prefs.diagnostics,prefs.product);
  IF NOT prefs.diagnostics THEN DELETE FROM api_private.telemetry_events WHERE user_id=owner_id AND kind IN('api','sync','crash','session'); END IF;
  IF NOT prefs.product THEN DELETE FROM api_private.telemetry_events WHERE user_id=owner_id AND kind IN('wardrobe_5','outfits_3'); END IF;
  result:=jsonb_build_object('data',api_private.telemetry_preferences_json(owner_id),'request_id',rid);
  UPDATE api_private.mutations SET response=result WHERE user_id=owner_id AND operation_id=operation;
  RETURN result;
 END IF;
 IF NOT request ?& ARRAY['version','events','probeActivation'] OR request-ARRAY['action','version','events','probeActivation']<>'{}'
 OR jsonb_typeof(request->'version') IS DISTINCT FROM 'number' OR coalesce(request->>'version','')!~'^[0-9]+$'
 OR jsonb_typeof(request->'events') IS DISTINCT FROM 'array' OR jsonb_array_length(request->'events')>20
 OR jsonb_typeof(request->'probeActivation') IS DISTINCT FROM 'boolean' THEN RAISE EXCEPTION USING ERRCODE='22023'; END IF;
 IF (request->>'version')::bigint<>prefs.version THEN RAISE EXCEPTION USING ERRCODE='P0002'; END IF;
 IF (jsonb_array_length(request->'events')>0 AND NOT prefs.diagnostics) OR ((request->>'probeActivation')::boolean AND NOT prefs.product) THEN
  RETURN jsonb_build_object('error',jsonb_build_object('code','telemetry_disabled','message','Telemetry not enabled','request_id',rid));
 END IF;
 DELETE FROM api_private.telemetry_events WHERE user_id=owner_id AND received_at<cutoff;
 SELECT count(*),count(*) FILTER(WHERE kind='crash') INTO count_today,crashes_today FROM api_private.telemetry_events
 WHERE user_id=owner_id AND received_at>=date_trunc('day',clock_timestamp() AT TIME ZONE 'UTC') AT TIME ZONE 'UTC';
 FOR item IN SELECT value FROM jsonb_array_elements(request->'events') LOOP
  IF jsonb_typeof(item) IS DISTINCT FROM 'object' OR NOT item ?& ARRAY['id','kind'] THEN RAISE EXCEPTION USING ERRCODE='22023'; END IF;
  event_id:=(item->>'id')::uuid; event_kind:=item->>'kind';
  IF event_id IS NULL OR event_kind IS NULL OR event_kind NOT IN('api','sync','session','crash') THEN RAISE EXCEPTION USING ERRCODE='22023'; END IF;
  IF event_kind IN('api','sync') THEN
   IF NOT item ?& ARRAY['route','outcome','durationMs'] OR item-ARRAY['id','kind','route','outcome','durationMs']<>'{}'
   OR jsonb_typeof(item->'durationMs') IS DISTINCT FROM 'number' OR coalesce(item->>'durationMs','')!~'^[0-9]+$'
   OR (item->>'durationMs')::bigint>3600000 OR coalesce(item->>'outcome','') NOT IN('success','offline','cancelled','unauthorized','conflict','rejected','server_error','invalid_response')
   OR (event_kind='api' AND NOT EXISTS(SELECT FROM pg_proc WHERE pronamespace='app'::regnamespace AND proname=item->>'route' AND proname LIKE 'api_v1_%' AND proname<>'api_v1_telemetry'))
   OR (event_kind='sync' AND item->>'route'<>'sync_cycle') THEN RAISE EXCEPTION USING ERRCODE='22023'; END IF;
  ELSIF event_kind='session' THEN
   IF item-ARRAY['id','kind']<>'{}' THEN RAISE EXCEPTION USING ERRCODE='22023'; END IF;
  ELSE
   IF NOT item ?& ARRAY['build','architecture','frames'] OR item-ARRAY['id','kind','build','architecture','frames']<>'{}'
   OR jsonb_typeof(item->'build') IS DISTINCT FROM 'string' OR coalesce(item->>'build','')!~'^[A-Za-z0-9._-]{1,40}$'
   OR coalesce(item->>'architecture','') NOT IN('arm64','arm64e','x86_64','unknown')
   OR jsonb_typeof(item->'frames') IS DISTINCT FROM 'array' OR jsonb_array_length(item->'frames')>64 THEN RAISE EXCEPTION USING ERRCODE='22023'; END IF;
   FOR frame IN SELECT value FROM jsonb_array_elements(item->'frames') LOOP
    IF jsonb_typeof(frame) IS DISTINCT FROM 'object' OR NOT frame ?& ARRAY['binaryUUID','offset'] OR frame-ARRAY['binaryUUID','offset']<>'{}'
    OR (frame->>'binaryUUID')::uuid IS NULL OR jsonb_typeof(frame->'offset') IS DISTINCT FROM 'number' OR coalesce(frame->>'offset','')!~'^[0-9]+$'
    OR (frame->>'offset')::numeric>9007199254740991 THEN RAISE EXCEPTION USING ERRCODE='22023'; END IF;
   END LOOP;
  END IF;
  SELECT data INTO existing FROM api_private.telemetry_events WHERE user_id=owner_id AND id=event_id;
  IF FOUND THEN
   IF existing<>item THEN RAISE EXCEPTION USING ERRCODE='22023'; END IF;
   accepted:=accepted+1; CONTINUE;
  END IF;
  IF count_today>=200 OR (event_kind='crash' AND crashes_today>=10) THEN
   RAISE EXCEPTION USING ERRCODE='P0003';
  END IF;
  INSERT INTO api_private.telemetry_events(user_id,id,kind,data) VALUES(owner_id,event_id,event_kind,item);
  count_today:=count_today+1; IF event_kind='crash' THEN crashes_today:=crashes_today+1; END IF;
  accepted:=accepted+1;
 END LOOP;
 IF (request->>'probeActivation')::boolean THEN
  -- Milestones are derived from committed owned rows, never client-supplied counts.
  IF (SELECT count(*) FROM app.garments WHERE user_id=owner_id AND deleted_at IS NULL)>=5 THEN
   INSERT INTO api_private.telemetry_events(user_id,id,kind,data) VALUES(owner_id,gen_random_uuid(),'wardrobe_5','{}') ON CONFLICT DO NOTHING;
  END IF;
  IF (SELECT count(*) FROM app.outfits WHERE user_id=owner_id AND deleted_at IS NULL)>=3 THEN
   INSERT INTO api_private.telemetry_events(user_id,id,kind,data) VALUES(owner_id,gen_random_uuid(),'outfits_3','{}') ON CONFLICT DO NOTHING;
  END IF;
 END IF;
 RETURN jsonb_build_object('data',jsonb_build_object('accepted',accepted,'version',prefs.version),'request_id',rid);
EXCEPTION WHEN invalid_text_representation OR numeric_value_out_of_range OR invalid_parameter_value OR check_violation THEN
 RETURN jsonb_build_object('error',jsonb_build_object('code','validation_failed','message','Invalid telemetry','request_id',rid));
 WHEN no_data_found THEN RETURN jsonb_build_object('error',jsonb_build_object('code','version_conflict','message','Telemetry choices changed; reload','request_id',rid));
 WHEN too_many_rows THEN RETURN jsonb_build_object('error',jsonb_build_object('code','rate_limited','message','Telemetry daily limit reached','request_id',rid));
END $$;
REVOKE ALL ON FUNCTION app.api_v1_telemetry(jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION app.api_v1_telemetry(jsonb) TO authenticated;

-- Include telemetry choices and retained diagnostics in the existing owner export.
ALTER FUNCTION api_private.export_snapshot(uuid) RENAME TO export_snapshot_pre025;
CREATE FUNCTION api_private.export_snapshot(owner_id uuid) RETURNS jsonb
LANGUAGE sql STABLE SET search_path=pg_catalog AS $$
 SELECT api_private.export_snapshot_pre025(owner_id)||jsonb_build_object(
  'telemetry_preferences',api_private.telemetry_preferences_json(owner_id),
  'telemetry_consent_changes',(SELECT coalesce(jsonb_agg(jsonb_build_object('version',version,'diagnostics',diagnostics,'product',product,'changed_at',changed_at) ORDER BY version),'[]'::jsonb)
    FROM api_private.telemetry_consent_changes WHERE user_id=owner_id),
  'telemetry_events',(SELECT coalesce(jsonb_agg(jsonb_build_object('received_at',received_at,'kind',kind,'data',data) ORDER BY received_at,id),'[]'::jsonb)
    FROM api_private.telemetry_events WHERE user_id=owner_id));
$$;
REVOKE ALL ON FUNCTION api_private.export_snapshot(uuid),api_private.export_snapshot_pre025(uuid) FROM PUBLIC,anon,authenticated,service_role;

-- No caller parameters and no diagnostic reads. The gateway's narrow service
-- role receives this single maintenance capability in neon-bootstrap.sql.
CREATE FUNCTION app.telemetry_prune() RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE removed integer;
BEGIN
 WITH expired AS (SELECT user_id,id FROM api_private.telemetry_events
  WHERE received_at<clock_timestamp()-interval '30 days' ORDER BY received_at LIMIT 10000 FOR UPDATE SKIP LOCKED)
 DELETE FROM api_private.telemetry_events e USING expired x WHERE e.user_id=x.user_id AND e.id=x.id;
 GET DIAGNOSTICS removed=ROW_COUNT; RETURN removed;
END $$;
REVOKE ALL ON FUNCTION app.telemetry_prune() FROM PUBLIC,anon,authenticated,service_role;
