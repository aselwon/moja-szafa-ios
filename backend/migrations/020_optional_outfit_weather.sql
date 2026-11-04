-- Optional coarse temperature only; no city or coordinates enter AI jobs.
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
      OR (pin IS NOT NULL AND NOT EXISTS(SELECT FROM app.garments WHERE id=pin AND user_id=owner_id AND deleted_at IS NULL AND archived_at IS NULL AND availability='available'))
      THEN RAISE EXCEPTION 'Invalid request' USING ERRCODE='22023'; END IF;
    job:=app.jobs_enqueue(owner_id,operation,'outfit_generation',request-'operation_id',1);
    RETURN jsonb_build_object('data',jsonb_build_object('job_id',job,'status',(SELECT status FROM app.ai_jobs WHERE id=job)),'request_id',rid);
EXCEPTION WHEN invalid_text_representation OR numeric_value_out_of_range OR invalid_parameter_value THEN
    code:=CASE SQLERRM WHEN 'AI disabled' THEN 'ai_disabled' WHEN 'AI quota exhausted' THEN 'quota_exceeded'
      WHEN 'AI consent required' THEN 'consent_required' ELSE 'validation_failed' END;
    RETURN jsonb_build_object('error',jsonb_build_object('code',code,'message','Request could not be accepted','request_id',rid));
WHEN OTHERS THEN RETURN jsonb_build_object('error',jsonb_build_object('code','internal_error','message','Request could not be completed','request_id',rid));
END $$;
