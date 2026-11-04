-- T032: personalization has its own revision; reset fences stale device writes.
CREATE TABLE api_private.personalization_revision (
 user_id uuid PRIMARY KEY REFERENCES app.profiles(user_id) ON DELETE CASCADE,
 version bigint NOT NULL DEFAULT 0 CHECK(version>=0)
);
REVOKE ALL ON api_private.personalization_revision FROM PUBLIC,anon,authenticated;
CREATE FUNCTION api_private.personalization_json(owner_id uuid,focus uuid DEFAULT NULL) RETURNS jsonb
LANGUAGE sql STABLE SET search_path=pg_catalog AS $$
 SELECT jsonb_build_object('version',coalesce((SELECT version FROM api_private.personalization_revision WHERE user_id=owner_id),0),
 'excludedCategories',coalesce((SELECT to_jsonb(excluded_categories) FROM app.preferences WHERE user_id=owner_id AND deleted_at IS NULL),'[]'::jsonb),
 'colors',coalesce((SELECT to_jsonb(colors) FROM app.preferences WHERE user_id=owner_id AND deleted_at IS NULL),'[]'::jsonb),
 'feedback',(SELECT jsonb_build_object('outfitID',f.outfit_id,'rating',f.rating,'reason',f.reason)
 FROM app.outfit_feedback f JOIN app.outfits o ON o.user_id=f.user_id AND o.id=f.outfit_id
 WHERE f.user_id=owner_id AND f.outfit_id=focus AND f.deleted_at IS NULL AND o.deleted_at IS NULL));
$$;
REVOKE ALL ON FUNCTION api_private.personalization_json(uuid,uuid) FROM PUBLIC,anon,authenticated;
CREATE FUNCTION app.api_v1_personalization(request jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE owner_id uuid:=auth.uid(); rid uuid:=gen_random_uuid(); action text:=request->>'action'; operation uuid;
 base bigint; current_version bigint; focus uuid; exclusions text[]; preferred_colors text[];
 previous api_private.mutations%ROWTYPE; result jsonb;
BEGIN
 IF owner_id IS NULL THEN RETURN jsonb_build_object('error',jsonb_build_object('code','unauthorized','message','Sign in required','request_id',rid)); END IF;
 -- One owner lock serializes preferences, feedback and reset, with deletion.
 PERFORM 1 FROM app.profiles WHERE user_id=owner_id AND deleted_at IS NULL FOR UPDATE;
 IF NOT FOUND THEN RETURN jsonb_build_object('error',jsonb_build_object('code','account_unavailable','message','Account unavailable','request_id',rid)); END IF;
 IF jsonb_typeof(request) IS DISTINCT FROM 'object' OR action IS NULL OR action NOT IN('get','preferences','feedback','reset') THEN RAISE EXCEPTION USING ERRCODE='22023'; END IF;
 focus:=(request->>'outfitID')::uuid;
 IF focus IS NOT NULL AND NOT EXISTS(SELECT FROM app.outfits WHERE user_id=owner_id AND id=focus AND deleted_at IS NULL) THEN RAISE EXCEPTION USING ERRCODE='22023'; END IF;
 IF action='get' THEN
  IF request-ARRAY['action','outfitID']<>'{}' THEN RAISE EXCEPTION USING ERRCODE='22023'; END IF;
  RETURN jsonb_build_object('data',api_private.personalization_json(owner_id,focus),'request_id',rid);
 END IF;
 IF NOT request ?& ARRAY['operationID','baseVersion'] OR jsonb_typeof(request->'baseVersion') IS DISTINCT FROM 'number'
 OR coalesce(request->>'baseVersion','') !~ '^[0-9]+$' THEN RAISE EXCEPTION USING ERRCODE='22023'; END IF;
 operation:=(request->>'operationID')::uuid; base:=(request->>'baseVersion')::bigint;
 IF operation IS NULL THEN RAISE EXCEPTION USING ERRCODE='22023'; END IF;
 IF action='preferences' THEN
  IF NOT request ?& ARRAY['excludedCategories','colors'] OR request-ARRAY['action','operationID','baseVersion','excludedCategories','colors']<>'{}'
  OR jsonb_typeof(request->'excludedCategories') IS DISTINCT FROM 'array' OR jsonb_typeof(request->'colors') IS DISTINCT FROM 'array' THEN RAISE EXCEPTION USING ERRCODE='22023'; END IF;
  SELECT coalesce(array_agg(value ORDER BY value),ARRAY[]::text[]) INTO exclusions FROM jsonb_array_elements_text(request->'excludedCategories');
  SELECT coalesce(array_agg(value ORDER BY value),ARRAY[]::text[]) INTO preferred_colors FROM jsonb_array_elements_text(request->'colors');
  IF cardinality(exclusions)>8 OR cardinality(exclusions)<>(SELECT count(DISTINCT x) FROM unnest(exclusions)x)
  OR EXISTS(SELECT FROM unnest(exclusions)x WHERE x IS NULL OR x<>ALL(ARRAY['top','bottom','shoes','dress','jumpsuit','outerwear','accessory','other']))
  OR cardinality(preferred_colors)>13 OR cardinality(preferred_colors)<>(SELECT count(DISTINCT x) FROM unnest(preferred_colors)x)
  OR EXISTS(SELECT FROM unnest(preferred_colors)x WHERE x IS NULL OR x<>ALL(ARRAY['black','white','gray','beige','brown','red','orange','yellow','green','blue','purple','pink','other'])) THEN RAISE EXCEPTION USING ERRCODE='22023'; END IF;
 ELSIF action='feedback' THEN
  IF focus IS NULL OR NOT request ? 'rating' OR request-ARRAY['action','operationID','baseVersion','outfitID','rating','reason']<>'{}'
  OR coalesce(request->>'rating','') NOT IN('like','dislike') OR (request ? 'reason' AND jsonb_typeof(request->'reason') NOT IN('string','null'))
  OR length(coalesce(request->>'reason',''))>500 THEN RAISE EXCEPTION USING ERRCODE='22023'; END IF;
 ELSE
  IF request-ARRAY['action','operationID','baseVersion']<>'{}' THEN RAISE EXCEPTION USING ERRCODE='22023'; END IF;
 END IF;
 INSERT INTO api_private.mutations VALUES(owner_id,operation,request,NULL) ON CONFLICT DO NOTHING;
 SELECT * INTO previous FROM api_private.mutations m WHERE m.user_id=owner_id AND m.operation_id=operation FOR UPDATE;
 IF previous.request<>request THEN RETURN jsonb_build_object('error',jsonb_build_object('code','idempotency_conflict','message','Operation already used','request_id',rid)); END IF;
 IF previous.response IS NOT NULL THEN RETURN previous.response; END IF;
 INSERT INTO api_private.personalization_revision(user_id) VALUES(owner_id) ON CONFLICT DO NOTHING;
 SELECT version INTO current_version FROM api_private.personalization_revision WHERE user_id=owner_id;
 IF current_version<>base THEN RAISE EXCEPTION USING ERRCODE='P0002'; END IF;
 IF action='preferences' THEN
  DELETE FROM app.preferences WHERE user_id=owner_id AND deleted_at IS NOT NULL;
  INSERT INTO app.preferences(user_id,colors,excluded_categories) VALUES(owner_id,preferred_colors,exclusions)
  ON CONFLICT(user_id) DO UPDATE SET colors=EXCLUDED.colors,excluded_categories=EXCLUDED.excluded_categories;
 ELSIF action='feedback' THEN
  DELETE FROM app.outfit_feedback WHERE user_id=owner_id AND outfit_id=focus AND deleted_at IS NOT NULL;
  INSERT INTO app.outfit_feedback(user_id,outfit_id,rating,reason) VALUES(owner_id,focus,request->>'rating',nullif(btrim(request->>'reason'),''))
  ON CONFLICT(user_id,outfit_id) DO UPDATE SET rating=EXCLUDED.rating,reason=EXCLUDED.reason;
 ELSE
  DELETE FROM app.preferences WHERE user_id=owner_id;
  DELETE FROM app.outfit_feedback WHERE user_id=owner_id;
 END IF;
 UPDATE api_private.personalization_revision SET version=version+1 WHERE user_id=owner_id;
 result:=jsonb_build_object('data',api_private.personalization_json(owner_id,focus),'request_id',rid);
 UPDATE api_private.mutations m SET response=result WHERE m.user_id=owner_id AND m.operation_id=operation;
 RETURN result;
EXCEPTION WHEN invalid_text_representation OR numeric_value_out_of_range OR invalid_parameter_value OR check_violation THEN
 RETURN jsonb_build_object('error',jsonb_build_object('code','validation_failed','message','Invalid personalization','request_id',rid));
 WHEN no_data_found THEN RETURN jsonb_build_object('error',jsonb_build_object('code','version_conflict','message','Personalization changed; reload','request_id',rid));
END $$;
REVOKE ALL ON FUNCTION app.api_v1_personalization(jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION app.api_v1_personalization(jsonb) TO authenticated;

CREATE FUNCTION api_private.category_excluded(owner_id uuid,category text) RETURNS boolean
LANGUAGE sql STABLE SET search_path=pg_catalog AS $$
 SELECT coalesce((SELECT category=ANY(excluded_categories) FROM app.preferences WHERE user_id=owner_id AND deleted_at IS NULL),false);
$$;
REVOKE ALL ON FUNCTION api_private.category_excluded(uuid,text) FROM PUBLIC,anon,authenticated;
CREATE FUNCTION api_private.filter_personalized_result(owner_id uuid,result jsonb) RETURNS jsonb
LANGUAGE plpgsql STABLE SET search_path=pg_catalog AS $$
DECLARE kept jsonb;
BEGIN
 IF result IS NULL OR result='null'::jsonb THEN RETURN result; END IF;
 IF jsonb_typeof(result->'outfits') IS DISTINCT FROM 'array' THEN RETURN NULL; END IF;
 SELECT coalesce(jsonb_agg(o.value ORDER BY o.ordinality),'[]'::jsonb) INTO kept
 FROM jsonb_array_elements(result->'outfits') WITH ORDINALITY o(value,ordinality)
 WHERE NOT EXISTS(SELECT FROM jsonb_array_elements_text(o.value->'garment_ids') i
   JOIN app.garments g ON g.id::text=i.value AND g.user_id=owner_id
   WHERE api_private.category_excluded(owner_id,g.category))
 AND NOT EXISTS(SELECT FROM app.purchase_candidates c WHERE c.user_id=owner_id
   AND c.id::text=o.value->>'purchase_candidate_id' AND api_private.category_excluded(owner_id,c.metadata->>'category'));
 IF kept=result->'outfits' THEN RETURN result; END IF;
 RETURN result||jsonb_build_object('outfits',kept,'shortfall_reason','Current exclusions removed some suggestions. Generate again for updated preferences.');
END $$;
REVOKE ALL ON FUNCTION api_private.filter_personalized_result(uuid,jsonb) FROM PUBLIC,anon,authenticated;


CREATE OR REPLACE FUNCTION app.ai_runtime_input(job_id uuid,token uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE j app.ai_jobs%ROWTYPE; payload jsonb; items jsonb; image_key text; candidate jsonb;
BEGIN
    IF NOT app.jobs_authorize_dispatch(job_id,token) THEN RETURN NULL; END IF;
    SELECT * INTO STRICT j FROM app.ai_jobs WHERE id=job_id;
    SELECT input INTO payload FROM api_private.job_payloads WHERE job_payloads.job_id=j.id;
    IF j.kind='image_analysis' THEN
        SELECT i.object_key INTO image_key FROM app.garment_images i
            JOIN api_private.image_uploads u ON i.object_key=u.id::text || '/thumbnail.jpg' AND u.user_id=i.user_id AND u.state='ready'
            JOIN app.garments g
            ON g.user_id=i.user_id AND g.id=i.garment_id
            WHERE u.id=(payload->>'image_id')::uuid AND i.user_id=j.user_id AND i.status='ready'
              AND i.deleted_at IS NULL AND g.deleted_at IS NULL AND i.variant='thumbnail';
        IF image_key IS NULL THEN RETURN NULL; END IF;
        RETURN jsonb_build_object('object_key',image_key,'mimeType','image/jpeg');
    ELSIF j.kind IN('outfit_generation','purchase_fit') THEN
        SELECT coalesce(jsonb_agg(jsonb_build_object('id',g.id,'user_id',g.user_id,'category',g.category,
            'colors',g.colors,'pattern',g.pattern,'seasons',g.seasons,'formality',g.formality,
            'availability',g.availability,'archived',g.archived_at IS NOT NULL,
            'preference_score',coalesce((SELECT greatest(-20,least(20,coalesce(sum(CASE f.rating WHEN 'like' THEN 2 ELSE -2 END),0))) FROM app.outfit_feedback f JOIN app.outfit_items i ON i.user_id=f.user_id AND i.outfit_id=f.outfit_id JOIN app.outfits o ON o.user_id=f.user_id AND o.id=f.outfit_id WHERE o.deleted_at IS NULL AND f.user_id=j.user_id AND f.deleted_at IS NULL AND i.deleted_at IS NULL AND i.garment_id=g.id),0))),'[]'::jsonb)
            INTO items FROM (SELECT * FROM app.garments WHERE user_id=j.user_id AND deleted_at IS NULL AND NOT api_private.category_excluded(j.user_id,category)
                ORDER BY id LIMIT 1001) g;
        IF jsonb_array_length(items)>1000 THEN RETURN NULL; END IF;
        IF j.kind='purchase_fit' THEN
            SELECT c.metadata||jsonb_build_object('id',c.id) INTO candidate FROM app.purchase_candidates c
             JOIN api_private.image_uploads u ON u.id=c.image_id AND u.user_id=c.user_id AND u.purchase_id=c.id AND u.state='ready'
             WHERE c.id=(payload->>'candidate_id')::uuid AND c.user_id=j.user_id AND c.deleted_at IS NULL AND c.status='considering' AND c.expires_at>clock_timestamp();
            IF candidate IS NULL OR api_private.category_excluded(j.user_id,candidate->>'category') THEN RETURN NULL; END IF;
            RETURN jsonb_build_object('garments',items,'purchase_candidate',candidate,'count',3);
        END IF;
        RETURN (payload - ARRAY['garments','user_id','owner','object_key','image_id']) || jsonb_build_object('garments',items,
          'preferences',coalesce(payload->'preferences','{}'::jsonb)||jsonb_build_object('colors',coalesce((SELECT to_jsonb(colors) FROM app.preferences WHERE user_id=j.user_id AND deleted_at IS NULL AND cardinality(colors)>0),payload#>'{preferences,colors}','[]'::jsonb)));
    END IF;
    RETURN NULL;
END $$;

CREATE OR REPLACE FUNCTION app.api_v1_generate_outfits(request jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE owner_id uuid:=auth.uid(); rid uuid:=gen_random_uuid(); operation uuid; pin uuid; count integer; job uuid; code text;
BEGIN
    IF owner_id IS NULL THEN RETURN jsonb_build_object('error',jsonb_build_object('code','unauthorized','message','Sign in required','request_id',rid)); END IF;
    IF NOT EXISTS(SELECT FROM app.profiles WHERE user_id=owner_id AND deleted_at IS NULL) THEN
        RETURN jsonb_build_object('error',jsonb_build_object('code','account_unavailable','message','Account unavailable','request_id',rid)); END IF;
    IF jsonb_typeof(request) IS DISTINCT FROM 'object' OR NOT request ?& ARRAY['operation_id','count','pinned_garment_id','preferences','occasion']
      OR request-ARRAY['operation_id','count','pinned_garment_id','preferences','occasion','weather']<>'{}'::jsonb
      OR jsonb_typeof(request->'count') IS DISTINCT FROM 'number' OR request->>'count' !~ '^[0-9]+$'
      OR jsonb_typeof(request->'preferences') IS DISTINCT FROM 'object' OR NOT (request->'preferences') ?& ARRAY['colors','seasons']
      OR (request->'preferences')-ARRAY['colors','seasons']<>'{}'::jsonb
      OR jsonb_typeof(request#>'{preferences,colors}') IS DISTINCT FROM 'array'
      OR jsonb_typeof(request#>'{preferences,seasons}') IS DISTINCT FROM 'array'
      OR jsonb_typeof(request->'occasion') IS DISTINCT FROM 'object' OR NOT (request->'occasion') ? 'formality'
      OR (request->'occasion')-'formality'<>'{}'::jsonb THEN RAISE EXCEPTION 'Invalid request' USING ERRCODE='22023'; END IF;
    IF request ? 'weather' AND request->'weather'<>'null'::jsonb THEN
      IF jsonb_typeof(request->'weather') IS DISTINCT FROM 'object'
        OR NOT (request->'weather') ?& ARRAY['source','temperature_celsius']
        OR jsonb_typeof(request#>'{weather,source}') IS DISTINCT FROM 'string'
        OR request#>>'{weather,source}' NOT IN ('manual','forecast')
        OR jsonb_typeof(request#>'{weather,temperature_celsius}') IS DISTINCT FROM 'number'
        OR (request#>>'{weather,temperature_celsius}')::numeric NOT BETWEEN -80 AND 60
        THEN RAISE EXCEPTION 'Invalid weather' USING ERRCODE='22023'; END IF;
      IF request#>>'{weather,source}'='manual' THEN
        IF (request->'weather')-ARRAY['source','temperature_celsius']<>'{}'::jsonb THEN RAISE EXCEPTION 'Invalid weather' USING ERRCODE='22023'; END IF;
      ELSE
        IF (request->'weather')-ARRAY['source','temperature_celsius','valid_until']<>'{}'::jsonb
          OR jsonb_typeof(request#>'{weather,valid_until}') IS DISTINCT FROM 'number'
          OR request#>>'{weather,valid_until}' !~ '^[0-9]{1,13}$'
          OR (request#>>'{weather,valid_until}')::numeric>extract(epoch from clock_timestamp())+7200
          THEN RAISE EXCEPTION 'Invalid weather' USING ERRCODE='22023'; END IF;
      END IF;
    END IF;
    operation:=(request->>'operation_id')::uuid; pin:=(request->>'pinned_garment_id')::uuid; count:=(request->>'count')::integer;
    IF operation IS NULL OR count NOT BETWEEN 1 AND 10
      OR jsonb_array_length(request#>'{preferences,colors}')>13 OR jsonb_array_length(request#>'{preferences,seasons}')>4
      OR (SELECT count(DISTINCT c) FROM jsonb_array_elements_text(request#>'{preferences,colors}') c)<>jsonb_array_length(request#>'{preferences,colors}')
      OR (SELECT count(DISTINCT c) FROM jsonb_array_elements_text(request#>'{preferences,seasons}') c)<>jsonb_array_length(request#>'{preferences,seasons}')
      OR EXISTS(SELECT FROM jsonb_array_elements_text(request#>'{preferences,colors}') c WHERE c IS NULL OR c<>ALL(ARRAY['black','white','gray','beige','brown','red','orange','yellow','green','blue','purple','pink','other']))
      OR EXISTS(SELECT FROM jsonb_array_elements_text(request#>'{preferences,seasons}') c WHERE c IS NULL OR c<>ALL(ARRAY['spring','summer','autumn','winter']))
      OR (request#>'{occasion,formality}'<>'null'::jsonb AND (jsonb_typeof(request#>'{occasion,formality}')<>'number' OR request#>>'{occasion,formality}' !~ '^[1-5]$'))
      OR (pin IS NOT NULL AND NOT EXISTS(SELECT FROM app.garments WHERE id=pin AND user_id=owner_id AND deleted_at IS NULL AND archived_at IS NULL AND availability='available' AND NOT api_private.category_excluded(owner_id,category)))
      THEN RAISE EXCEPTION 'Invalid request' USING ERRCODE='22023'; END IF;
    job:=app.jobs_enqueue(owner_id,operation,'outfit_generation',request-'operation_id',1);
    RETURN jsonb_build_object('data',jsonb_build_object('job_id',job,'status',(SELECT status FROM app.ai_jobs WHERE id=job)),'request_id',rid);
EXCEPTION WHEN invalid_text_representation OR numeric_value_out_of_range OR invalid_parameter_value THEN
    code:=CASE SQLERRM WHEN 'AI disabled' THEN 'ai_disabled' WHEN 'AI quota exhausted' THEN 'quota_exceeded'
      WHEN 'AI consent required' THEN 'consent_required' ELSE 'validation_failed' END;
    RETURN jsonb_build_object('error',jsonb_build_object('code',code,'message','Request could not be accepted','request_id',rid));
WHEN OTHERS THEN RETURN jsonb_build_object('error',jsonb_build_object('code','internal_error','message','Request could not be completed','request_id',rid));
END $$;

CREATE OR REPLACE FUNCTION app.api_v1_latest_suggestions(request jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
DECLARE owner_id uuid := auth.uid(); request_id uuid := gen_random_uuid(); result jsonb;
BEGIN
    IF owner_id IS NULL THEN
        RETURN jsonb_build_object('error',jsonb_build_object('code','unauthorized','message','Sign in required','request_id',request_id));
    END IF;
    IF NOT EXISTS (SELECT FROM app.profiles WHERE user_id = owner_id AND deleted_at IS NULL) THEN
        RETURN jsonb_build_object('error',jsonb_build_object('code','account_unavailable','message','Account unavailable','request_id',request_id));
    END IF;
    IF request IS DISTINCT FROM '{}'::jsonb THEN
        RETURN jsonb_build_object('error',jsonb_build_object('code','validation_failed','message','Expected empty request','request_id',request_id));
    END IF;
    SELECT p.result->'result' INTO result
        FROM app.ai_jobs j JOIN api_private.job_payloads p ON p.job_id = j.id
        WHERE j.user_id = owner_id AND j.deleted_at IS NULL
          AND j.kind = 'outfit_generation' AND j.status = 'succeeded'
        ORDER BY j.finished_at DESC, j.id DESC LIMIT 1;
    RETURN jsonb_build_object('data',api_private.filter_personalized_result(owner_id,result),'request_id',request_id);
END $$;

CREATE OR REPLACE FUNCTION app.api_v1_save_suggestion(request jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
DECLARE owner_id uuid := auth.uid(); request_id uuid := gen_random_uuid(); ids uuid[];
BEGIN
    -- The existing RPC handles auth, exact shape, replay and version conflicts.
    -- A successful replay must still work after a garment moves to laundry.
    IF owner_id IS NULL OR EXISTS (SELECT FROM api_private.mutations m
        WHERE m.user_id = owner_id AND m.operation_id = (api_v1_save_suggestion.request->>'operationID')::uuid
          AND m.response IS NOT NULL) THEN
        RETURN app.api_v1_save_outfit(request);
    END IF;
    PERFORM 1 FROM app.profiles WHERE user_id=owner_id AND deleted_at IS NULL FOR SHARE;
    SELECT array_agg(value::uuid) INTO ids FROM jsonb_array_elements_text(request->'garmentIDs');
    PERFORM g.id FROM app.garments g WHERE g.user_id = owner_id AND g.id = ANY(ids) ORDER BY g.id FOR SHARE;
    IF cardinality(ids) IS NULL OR (SELECT count(*) FROM app.garments g
        WHERE g.user_id = owner_id AND g.id = ANY(ids) AND g.deleted_at IS NULL
          AND g.archived_at IS NULL AND g.availability = 'available' AND NOT api_private.category_excluded(owner_id,g.category)) <> cardinality(ids) THEN
        RAISE EXCEPTION USING ERRCODE = '22023';
    END IF;
    RETURN app.api_v1_save_outfit(request);
EXCEPTION WHEN invalid_text_representation OR invalid_parameter_value THEN
    RETURN jsonb_build_object('error',jsonb_build_object('code','validation_failed','message','Suggestion items unavailable','request_id',request_id));
END $$;

CREATE OR REPLACE FUNCTION app.api_v1_job_result(request jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE owner_id uuid:=auth.uid(); rid uuid:=gen_random_uuid(); job uuid; result jsonb;
BEGIN
    IF owner_id IS NULL THEN RETURN jsonb_build_object('error',jsonb_build_object('code','unauthorized','message','Sign in required','request_id',rid)); END IF;
    IF NOT EXISTS(SELECT FROM app.profiles WHERE user_id=owner_id AND deleted_at IS NULL) THEN
      RETURN jsonb_build_object('error',jsonb_build_object('code','account_unavailable','message','Account unavailable','request_id',rid)); END IF;
    IF jsonb_typeof(request) IS DISTINCT FROM 'object' OR NOT request ? 'job_id' OR request-'job_id'<>'{}'::jsonb THEN
      RAISE EXCEPTION 'Invalid request' USING ERRCODE='22023'; END IF;
    job:=(request->>'job_id')::uuid;
    IF job IS NULL THEN RAISE EXCEPTION 'Invalid request' USING ERRCODE='22023'; END IF;
    SELECT jsonb_build_object('job_id',j.id,'kind',j.kind,'status',j.status,'error_code',j.error_code,
      'result',CASE WHEN j.status='succeeded' THEN api_private.filter_personalized_result(owner_id,p.result->'result') ELSE NULL END) INTO result
      FROM app.ai_jobs j JOIN api_private.job_payloads p ON p.job_id=j.id
      WHERE j.id=job AND j.user_id=owner_id AND j.kind='outfit_generation' AND j.deleted_at IS NULL;
    IF result IS NULL THEN RETURN jsonb_build_object('error',jsonb_build_object('code','not_found','message','Job unavailable','request_id',rid)); END IF;
    RETURN jsonb_build_object('data',result,'request_id',rid);
EXCEPTION WHEN invalid_text_representation OR invalid_parameter_value THEN
    RETURN jsonb_build_object('error',jsonb_build_object('code','validation_failed','message','Invalid request','request_id',rid));
WHEN OTHERS THEN RETURN jsonb_build_object('error',jsonb_build_object('code','internal_error','message','Request could not be completed','request_id',rid));
END $$;

CREATE OR REPLACE FUNCTION app.api_v1_purchase_fit_result(request jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE owner_id uuid:=auth.uid(); rid uuid:=gen_random_uuid(); job uuid; result jsonb;
BEGIN
    IF owner_id IS NULL THEN RETURN jsonb_build_object('error',jsonb_build_object('code','unauthorized','message','Sign in required','request_id',rid)); END IF;
    IF NOT EXISTS(SELECT FROM app.profiles WHERE user_id=owner_id AND deleted_at IS NULL) THEN
      RETURN jsonb_build_object('error',jsonb_build_object('code','account_unavailable','message','Account unavailable','request_id',rid)); END IF;
    IF jsonb_typeof(request) IS DISTINCT FROM 'object' OR NOT request ? 'job_id' OR request-'job_id'<>'{}'::jsonb THEN
      RAISE EXCEPTION 'Invalid request' USING ERRCODE='22023'; END IF;
    job:=(request->>'job_id')::uuid;
    IF job IS NULL THEN RAISE EXCEPTION 'Invalid request' USING ERRCODE='22023'; END IF;
    SELECT jsonb_build_object('job_id',j.id,'kind',j.kind,'status',j.status,'error_code',j.error_code,
      'result',CASE WHEN j.status='succeeded' THEN api_private.filter_personalized_result(owner_id,p.result->'result') ELSE NULL END) INTO result
      FROM app.ai_jobs j JOIN api_private.job_payloads p ON p.job_id=j.id
      WHERE j.id=job AND j.user_id=owner_id AND j.kind='purchase_fit' AND j.deleted_at IS NULL;
    IF result IS NULL THEN RETURN jsonb_build_object('error',jsonb_build_object('code','not_found','message','Job unavailable','request_id',rid)); END IF;
    RETURN jsonb_build_object('data',result,'request_id',rid);
EXCEPTION WHEN invalid_text_representation OR invalid_parameter_value THEN
    RETURN jsonb_build_object('error',jsonb_build_object('code','validation_failed','message','Invalid request','request_id',rid));
WHEN OTHERS THEN RETURN jsonb_build_object('error',jsonb_build_object('code','internal_error','message','Request could not be completed','request_id',rid));
END $$;
