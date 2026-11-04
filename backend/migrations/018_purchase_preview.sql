-- Temporary purchase candidates never enter owned wardrobe until confirmation.
ALTER TABLE app.purchase_candidates ADD COLUMN metadata jsonb NOT NULL DEFAULT '{}'::jsonb;
ALTER TABLE app.purchase_candidates ADD COLUMN price_grosz bigint CHECK(price_grosz >= 0);
ALTER TABLE app.purchase_candidates ADD COLUMN image_id uuid;
ALTER TABLE api_private.image_uploads ALTER COLUMN garment_id DROP NOT NULL;
ALTER TABLE api_private.image_uploads ADD COLUMN purchase_id uuid;
ALTER TABLE api_private.image_uploads ADD CONSTRAINT image_one_parent CHECK ((garment_id IS NULL) <> (purchase_id IS NULL));
CREATE UNIQUE INDEX purchase_single_image ON api_private.image_uploads(user_id,purchase_id) WHERE purchase_id IS NOT NULL;

CREATE OR REPLACE FUNCTION app.images_command(request jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
DECLARE
    action text := request->>'action';
    owner_id uuid := (request->>'owner')::uuid;
    operation_id uuid := (request->>'id')::uuid;
    garment uuid := (request->>'garment')::uuid;
    row api_private.image_uploads%ROWTYPE;
    result jsonb;
BEGIN
    IF action = 'sweep' THEN
        -- Fence publication before removing bytes. Retired records survive and
        -- are swept repeatedly, including after restores or a delayed writer.
        result := '[]'::jsonb;
        -- The locking SELECT can have an older snapshot than a concurrent parent
        -- transfer. Recheck in a separate statement AFTER acquiring each upload
        -- lock, so a newly committed garment/image pair is visible before retire.
        FOR row IN
            SELECT u.* FROM api_private.image_uploads u
            WHERE u.next_cleanup_at <= clock_timestamp() AND (
                u.state = 'retired' OR
                (u.state IN ('pending','processing') AND u.expires_at <= clock_timestamp()) OR
                NOT EXISTS (SELECT FROM app.profiles p WHERE p.user_id = u.user_id AND p.deleted_at IS NULL) OR
                (u.purchase_id IS NULL AND NOT EXISTS (SELECT FROM app.garments g WHERE g.id = u.garment_id AND g.user_id = u.user_id AND g.deleted_at IS NULL)) OR
                (u.purchase_id IS NOT NULL AND NOT EXISTS (SELECT FROM app.purchase_candidates c WHERE c.id=u.purchase_id AND c.user_id=u.user_id AND c.deleted_at IS NULL AND c.status='considering' AND c.expires_at>clock_timestamp())) OR
                (u.purchase_id IS NULL AND u.state = 'ready' AND (SELECT count(*) FROM app.garment_images i
                    WHERE i.user_id = u.user_id AND i.garment_id = u.garment_id AND i.deleted_at IS NULL
                    AND i.status = 'ready' AND i.object_key IN (u.id::text || '/original.jpg', u.id::text || '/thumbnail.jpg')) <> 2)

            ) ORDER BY u.next_cleanup_at,u.id FOR UPDATE SKIP LOCKED LIMIT 100
        LOOP
            IF EXISTS (SELECT FROM api_private.image_uploads u WHERE u.id=row.id AND (
                u.state = 'retired' OR
                (u.state IN ('pending','processing') AND u.expires_at <= clock_timestamp()) OR
                NOT EXISTS (SELECT FROM app.profiles p WHERE p.user_id = u.user_id AND p.deleted_at IS NULL) OR
                (u.purchase_id IS NULL AND NOT EXISTS (SELECT FROM app.garments g WHERE g.id = u.garment_id AND g.user_id = u.user_id AND g.deleted_at IS NULL)) OR
                (u.purchase_id IS NOT NULL AND NOT EXISTS (SELECT FROM app.purchase_candidates c WHERE c.id=u.purchase_id AND c.user_id=u.user_id AND c.deleted_at IS NULL AND c.status='considering' AND c.expires_at>clock_timestamp())) OR
                (u.purchase_id IS NULL AND u.state = 'ready' AND (SELECT count(*) FROM app.garment_images i
                    WHERE i.user_id = u.user_id AND i.garment_id = u.garment_id AND i.deleted_at IS NULL
                    AND i.status = 'ready' AND i.object_key IN (u.id::text || '/original.jpg', u.id::text || '/thumbnail.jpg')) <> 2)

            )) THEN
                UPDATE api_private.image_uploads SET state='retired',fence=NULL WHERE id=row.id;
                result := result || jsonb_build_array(jsonb_build_object('id',row.id));
            END IF;
        END LOOP;
        RETURN result;
    ELSIF action = 'cleaned' THEN
        DELETE FROM app.garment_images i USING api_private.image_uploads u
        WHERE u.id = operation_id AND u.state = 'retired'
          AND i.object_key IN (u.id::text || '/original.jpg', u.id::text || '/thumbnail.jpg');
        UPDATE api_private.image_uploads SET next_cleanup_at = clock_timestamp() + interval '1 hour'
        WHERE id = operation_id AND state = 'retired';
        RETURN 'true'::jsonb;
    END IF;
    IF owner_id IS NULL OR operation_id IS NULL THEN RETURN 'null'::jsonb; END IF;
    -- Lock live parents so deletion cannot race publication in this transaction.
    PERFORM 1 FROM app.profiles WHERE user_id = owner_id AND deleted_at IS NULL FOR SHARE;
    IF NOT FOUND THEN RETURN 'null'::jsonb; END IF;
    IF action = 'prepare' THEN
        PERFORM 1 FROM app.garments WHERE id = garment AND user_id = owner_id AND deleted_at IS NULL FOR SHARE;
        IF NOT FOUND THEN RETURN 'null'::jsonb; END IF;
        INSERT INTO api_private.image_uploads(id,user_id,garment_id) VALUES(operation_id,owner_id,garment)
        ON CONFLICT DO NOTHING;
    END IF;
    SELECT * INTO row FROM api_private.image_uploads WHERE id = operation_id AND user_id = owner_id FOR UPDATE;
    IF NOT FOUND OR row.state = 'retired' THEN RETURN 'null'::jsonb; END IF;
    PERFORM 1 FROM app.garments WHERE id = row.garment_id AND user_id = owner_id AND deleted_at IS NULL FOR SHARE;
    IF NOT FOUND THEN RETURN 'null'::jsonb; END IF;
    IF action = 'prepare' THEN
        IF row.garment_id <> garment OR (row.state <> 'ready' AND row.expires_at <= clock_timestamp()) THEN
            RETURN 'null'::jsonb;
        END IF;
        RETURN jsonb_build_object('id',row.id);
    ELSIF action = 'claim' THEN
        IF row.state = 'ready' THEN RETURN jsonb_build_object('state','ready'); END IF;
        IF row.state <> 'pending' OR row.expires_at <= clock_timestamp() THEN RETURN 'null'::jsonb; END IF;
        UPDATE api_private.image_uploads SET state = 'processing', fence = gen_random_uuid(),
            expires_at = clock_timestamp() + interval '60 seconds' WHERE id = row.id RETURNING * INTO row;
        RETURN jsonb_build_object('state',row.state,'fence',row.fence);
    ELSIF action = 'finish' THEN
        IF row.state <> 'processing' OR row.fence IS DISTINCT FROM (request->>'fence')::uuid
           OR row.expires_at <= clock_timestamp() THEN RETURN 'null'::jsonb; END IF;
        -- An upload never silently replaces another operation's image variants.
        INSERT INTO app.garment_images(user_id,garment_id,variant,object_key,status,content_type)
        VALUES(owner_id,row.garment_id,'original',row.id::text || '/original.jpg','ready','image/jpeg'),
              (owner_id,row.garment_id,'thumbnail',row.id::text || '/thumbnail.jpg','ready','image/jpeg');
        UPDATE api_private.image_uploads SET state = 'ready',fence = NULL WHERE id = row.id;
        RETURN 'true'::jsonb;
    ELSIF action = 'read' THEN
        RETURN to_jsonb(row.state = 'ready' AND (SELECT count(*) FROM app.garment_images i
            WHERE i.user_id = owner_id AND i.garment_id = row.garment_id AND i.deleted_at IS NULL
              AND i.status = 'ready' AND i.object_key IN (row.id::text || '/original.jpg',row.id::text || '/thumbnail.jpg')) = 2);
    END IF;
    RETURN 'null'::jsonb;
END $$;

CREATE FUNCTION app.purchase_images_command(request jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE action text:=request->>'action'; owner_id uuid:=(request->>'owner')::uuid;
 image uuid:=(request->>'id')::uuid; candidate uuid:=(request->>'garment')::uuid;
 row api_private.image_uploads%ROWTYPE; c app.purchase_candidates%ROWTYPE;
BEGIN
 IF owner_id IS NULL OR image IS NULL OR action NOT IN ('prepare','claim','finish','read') THEN RETURN NULL; END IF;
 PERFORM 1 FROM app.profiles WHERE user_id=owner_id AND deleted_at IS NULL FOR SHARE;
 IF NOT FOUND THEN RETURN NULL; END IF;
 IF action<>'prepare' THEN SELECT purchase_id INTO candidate FROM api_private.image_uploads WHERE id=image AND user_id=owner_id; END IF;
 SELECT * INTO c FROM app.purchase_candidates WHERE id=candidate AND user_id=owner_id FOR UPDATE;
 IF NOT FOUND OR c.deleted_at IS NOT NULL OR c.status<>'considering' OR c.expires_at<=clock_timestamp() THEN RETURN NULL; END IF;
 IF action='prepare' THEN
  INSERT INTO api_private.image_uploads(id,user_id,garment_id,purchase_id) VALUES(image,owner_id,NULL,candidate) ON CONFLICT DO NOTHING;
 END IF;
 SELECT * INTO row FROM api_private.image_uploads WHERE id=image AND user_id=owner_id AND purchase_id=candidate FOR UPDATE;
 IF NOT FOUND OR row.state='retired' THEN RETURN NULL; END IF;
 IF action='prepare' THEN
  IF row.state<>'ready' AND row.expires_at<=clock_timestamp() THEN RETURN NULL; END IF;
  RETURN jsonb_build_object('id',row.id);
 ELSIF action='claim' THEN
  IF row.state='ready' THEN RETURN jsonb_build_object('state','ready'); END IF;
  IF row.state<>'pending' OR row.expires_at<=clock_timestamp() THEN RETURN NULL; END IF;
  UPDATE api_private.image_uploads SET state='processing',fence=gen_random_uuid(),expires_at=clock_timestamp()+interval '60 seconds' WHERE id=image RETURNING * INTO row;
  RETURN jsonb_build_object('state',row.state,'fence',row.fence);
 ELSIF action='finish' THEN
  IF row.state<>'processing' OR row.fence IS DISTINCT FROM (request->>'fence')::uuid OR row.expires_at<=clock_timestamp() THEN RETURN NULL; END IF;
  UPDATE api_private.image_uploads SET state='ready',fence=NULL WHERE id=image;
  UPDATE app.purchase_candidates SET image_id=image,object_key=image::text||'/original.jpg' WHERE id=candidate;
  RETURN 'true'::jsonb;
 ELSIF action='read' THEN RETURN to_jsonb(row.state='ready' AND c.image_id=image);
 END IF;
 RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION app.purchase_images_command(jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION app.purchase_images_command(jsonb) TO service_role;

CREATE FUNCTION api_private.purchase_json(c app.purchase_candidates) RETURNS jsonb
LANGUAGE sql STABLE SET search_path=pg_catalog AS $$
 SELECT jsonb_build_object('id',c.id,'name',c.name,'metadata',c.metadata,'price_grosz',c.price_grosz,
 'image_id',c.image_id,'expires_at',extract(epoch from c.expires_at),'status',c.status,'garment_id',c.purchased_garment_id)
$$;
REVOKE ALL ON FUNCTION api_private.purchase_json(app.purchase_candidates) FROM PUBLIC,anon,authenticated;

CREATE FUNCTION app.api_v1_purchase(request jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE owner_id uuid:=auth.uid(); rid uuid:=gen_random_uuid(); action text:=request->>'action';
 candidate uuid; operation uuid; c app.purchase_candidates%ROWTYPE; previous api_private.mutations%ROWTYPE;
 metadata jsonb:=request->'metadata'; result jsonb; garment uuid; image api_private.image_uploads%ROWTYPE;
BEGIN
 IF owner_id IS NULL THEN RETURN jsonb_build_object('error',jsonb_build_object('code','unauthorized','message','Sign in required','request_id',rid)); END IF;
 PERFORM 1 FROM app.profiles WHERE user_id=owner_id AND deleted_at IS NULL FOR SHARE;
 IF NOT FOUND THEN RETURN jsonb_build_object('error',jsonb_build_object('code','account_unavailable','message','Account unavailable','request_id',rid)); END IF;
 IF jsonb_typeof(request) IS DISTINCT FROM 'object' OR action IS NULL OR action NOT IN('create','list','get','confirm','discard') THEN RAISE EXCEPTION USING ERRCODE='22023'; END IF;
 IF action='list' THEN
  IF request-ARRAY['action']<>'{}'::jsonb THEN RAISE EXCEPTION USING ERRCODE='22023'; END IF;
  SELECT coalesce(jsonb_agg(api_private.purchase_json(x) ORDER BY x.created_at DESC),'[]'::jsonb) INTO result
   FROM (SELECT * FROM app.purchase_candidates WHERE user_id=owner_id AND deleted_at IS NULL AND status='considering' AND expires_at>clock_timestamp() ORDER BY created_at DESC LIMIT 50) x;
  RETURN jsonb_build_object('data',result,'request_id',rid);
 END IF;
 candidate:=(request->>'candidate_id')::uuid;
 IF candidate IS NULL THEN RAISE EXCEPTION USING ERRCODE='22023'; END IF;
 IF action='get' THEN
  IF request-ARRAY['action','candidate_id']<>'{}'::jsonb THEN RAISE EXCEPTION USING ERRCODE='22023'; END IF;
 ELSE
  operation:=(request->>'operation_id')::uuid;
  IF operation IS NULL THEN RAISE EXCEPTION USING ERRCODE='22023'; END IF;
  IF action='create' THEN
   IF NOT request ?& ARRAY['name','metadata','price_grosz'] OR request-ARRAY['action','operation_id','candidate_id','name','metadata','price_grosz']<>'{}'::jsonb
    OR jsonb_typeof(request->'name') IS DISTINCT FROM 'string' OR length(btrim(request->>'name')) NOT BETWEEN 1 AND 200
    OR jsonb_typeof(metadata) IS DISTINCT FROM 'object' OR NOT metadata ?& ARRAY['category','colors','seasons','formality']
    OR metadata-ARRAY['category','colors','seasons','formality']<>'{}'::jsonb
    OR jsonb_typeof(metadata->'category') IS DISTINCT FROM 'string' OR metadata->>'category' NOT IN('top','bottom','shoes','dress','jumpsuit','outerwear','accessory','other')
    OR jsonb_typeof(metadata->'colors') IS DISTINCT FROM 'array' OR jsonb_typeof(metadata->'seasons') IS DISTINCT FROM 'array'
    OR jsonb_array_length(metadata->'colors')>13 OR jsonb_array_length(metadata->'seasons')>4
    OR NOT (metadata->'colors' <@ '["black","white","gray","beige","brown","red","orange","yellow","green","blue","purple","pink","other"]'::jsonb)
    OR NOT (metadata->'seasons' <@ '["spring","summer","autumn","winter"]'::jsonb)
    OR (metadata->'formality'<>'null'::jsonb AND (jsonb_typeof(metadata->'formality')<>'number' OR metadata->>'formality' NOT IN('1','2','3','4','5')))
    OR (request->'price_grosz'<>'null'::jsonb AND (jsonb_typeof(request->'price_grosz')<>'number' OR request->>'price_grosz' !~ '^[0-9]+$'))
    THEN RAISE EXCEPTION USING ERRCODE='22023'; END IF;
  ELSIF action='confirm' THEN
   IF request->'confirmed' IS DISTINCT FROM 'true'::jsonb OR request-ARRAY['action','operation_id','candidate_id','confirmed']<>'{}'::jsonb THEN RAISE EXCEPTION USING ERRCODE='22023'; END IF;
  ELSIF request-ARRAY['action','operation_id','candidate_id']<>'{}'::jsonb THEN RAISE EXCEPTION USING ERRCODE='22023'; END IF;
  INSERT INTO api_private.mutations(user_id,operation_id,request) VALUES(owner_id,operation,request) ON CONFLICT DO NOTHING;
  SELECT * INTO previous FROM api_private.mutations m WHERE m.user_id=owner_id AND m.operation_id=operation FOR UPDATE;
  IF previous.request<>request THEN RETURN jsonb_build_object('error',jsonb_build_object('code','idempotency_conflict','message','Intent changed','request_id',rid)); END IF;
  IF previous.response IS NOT NULL THEN RETURN previous.response; END IF;
 END IF;
 IF action='create' THEN
  INSERT INTO app.purchase_candidates(id,user_id,name,metadata,price_grosz,expires_at)
   VALUES(candidate,owner_id,btrim(request->>'name'),metadata,(request->>'price_grosz')::bigint,clock_timestamp()+interval '7 days') RETURNING * INTO c;
 ELSE
  SELECT * INTO c FROM app.purchase_candidates WHERE id=candidate AND user_id=owner_id AND deleted_at IS NULL FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='P0002'; END IF;
  IF action='confirm' AND c.status='purchased' THEN
   -- Candidate-level deduplication also covers different operation UUIDs/devices.
   result:=jsonb_build_object('data',api_private.purchase_json(c),'request_id',rid);
  ELSE
   IF c.status<>'considering' OR c.expires_at<=clock_timestamp() THEN RAISE EXCEPTION USING ERRCODE='P0002'; END IF;
   IF action='confirm' THEN
    SELECT * INTO image FROM api_private.image_uploads WHERE id=c.image_id AND user_id=owner_id AND purchase_id=c.id AND state='ready' FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='22023'; END IF;
    garment:=gen_random_uuid();
    INSERT INTO app.garments(id,user_id,name,category,colors,seasons,formality,price_grosz,purchased_on)
    VALUES(garment,owner_id,c.name,c.metadata->>'category',ARRAY(SELECT jsonb_array_elements_text(c.metadata->'colors')),
     ARRAY(SELECT jsonb_array_elements_text(c.metadata->'seasons')),(c.metadata->>'formality')::smallint,c.price_grosz,current_date);
    INSERT INTO app.garment_images(user_id,garment_id,variant,object_key,status,content_type)
     VALUES(owner_id,garment,'original',image.id::text||'/original.jpg','ready','image/jpeg'),(owner_id,garment,'thumbnail',image.id::text||'/thumbnail.jpg','ready','image/jpeg');
    UPDATE api_private.image_uploads SET garment_id=garment,purchase_id=NULL WHERE id=image.id;
    UPDATE app.purchase_candidates SET status='purchased',purchased_garment_id=garment WHERE id=c.id RETURNING * INTO c;
   ELSIF action='discard' THEN
    UPDATE app.purchase_candidates SET status='discarded',deleted_at=clock_timestamp() WHERE id=c.id RETURNING * INTO c;
   END IF;
  END IF;
 END IF;
 result:=coalesce(result,jsonb_build_object('data',api_private.purchase_json(c),'request_id',rid));
 IF operation IS NOT NULL THEN UPDATE api_private.mutations m SET response=result WHERE m.user_id=owner_id AND m.operation_id=operation; END IF;
 RETURN result;
EXCEPTION
 WHEN no_data_found THEN RETURN jsonb_build_object('error',jsonb_build_object('code','not_found','message','Candidate unavailable','request_id',rid));
 WHEN invalid_text_representation OR numeric_value_out_of_range OR invalid_parameter_value OR check_violation OR unique_violation THEN
 RETURN jsonb_build_object('error',jsonb_build_object('code','validation_failed','message','Invalid purchase request','request_id',rid));
END $$;
REVOKE ALL ON FUNCTION app.api_v1_purchase(jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION app.api_v1_purchase(jsonb) TO authenticated;


CREATE OR REPLACE FUNCTION app.jobs_enqueue(owner_id uuid,operation_id uuid,job_kind text,payload jsonb,units integer DEFAULT 1) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE policy api_private.ai_policy%ROWTYPE; day_start timestamptz := date_trunc('day',clock_timestamp() AT TIME ZONE 'UTC') AT TIME ZONE 'UTC';
    used_global bigint; used_user bigint; reserve_units integer; admitted uuid; replay_units integer;
BEGIN
    IF units IS NULL OR units<1 OR units>500000 THEN RAISE EXCEPTION 'Invalid units' USING ERRCODE='22023'; END IF;
    reserve_units := units * CASE WHEN job_kind IN('outfit_generation','purchase_fit') THEN 2 ELSE 1 END;
    -- A single policy lock serializes admission and dispatch across every worker.
    SELECT * INTO STRICT policy FROM api_private.ai_policy FOR UPDATE;
    IF NOT policy.enabled OR (job_kind='image_analysis' AND NOT policy.image_enabled) THEN RAISE EXCEPTION 'AI disabled' USING ERRCODE='22023'; END IF;
    -- Preserve exact durable replay even when the remaining budget is now exhausted.
    IF EXISTS(SELECT FROM app.ai_jobs WHERE user_id=owner_id AND client_request_id=operation_id) THEN
        SELECT CASE WHEN j.pricing_version='call-credits-v1' THEN reserve_units ELSE units END INTO replay_units
          FROM app.ai_jobs j WHERE j.user_id=owner_id AND j.client_request_id=operation_id;
        RETURN app.jobs_enqueue_with_consent(owner_id,operation_id,job_kind,payload,replay_units);
    END IF;
    IF units IS NULL OR units<1 THEN RAISE EXCEPTION 'Invalid units' USING ERRCODE='22023'; END IF;
    SELECT coalesce(sum(r.units),0) INTO used_user FROM app.usage_reservations r
        WHERE r.user_id=owner_id AND (r.status='reserved' OR r.created_at>=day_start OR EXISTS(SELECT FROM api_private.ai_dispatch_receipts d WHERE d.job_id=r.ai_job_id AND d.dispatched_at>=day_start))
        AND (r.status IN('reserved','settled') OR EXISTS(SELECT FROM api_private.ai_dispatch_receipts d WHERE d.job_id=r.ai_job_id));
    SELECT coalesce(sum(greatest(0,r.units-coalesce((SELECT sum(d.units) FROM api_private.ai_dispatch_receipts d WHERE d.job_id=r.ai_job_id),0))),0) INTO used_global FROM app.usage_reservations r
        WHERE r.status='reserved' OR (r.status='settled' AND r.created_at>=day_start);
    used_global := used_global + coalesce((SELECT d.units FROM api_private.ai_daily_dispatch d WHERE d.day=(day_start AT TIME ZONE 'UTC')::date),0);
    IF used_user+reserve_units>policy.daily_user_units OR used_global+reserve_units>policy.daily_global_units THEN
        RAISE EXCEPTION 'AI quota exhausted' USING ERRCODE='22023'; END IF;
    admitted:=app.jobs_enqueue_with_consent(owner_id,operation_id,job_kind,payload,reserve_units);
    UPDATE app.ai_jobs SET pricing_version='call-credits-v1' WHERE id=admitted;
    RETURN admitted;
END $$;


CREATE OR REPLACE FUNCTION app.ai_runtime_dispatch(job_id uuid,token uuid,recipient text) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE policy api_private.ai_policy%ROWTYPE; amount integer; call_number integer := 1; j app.ai_jobs%ROWTYPE; current_day date := (clock_timestamp() AT TIME ZONE 'UTC')::date;
BEGIN
    SELECT * INTO STRICT policy FROM api_private.ai_policy FOR UPDATE;
    IF NOT policy.enabled OR policy.recipient IS DISTINCT FROM recipient
       OR NOT EXISTS(SELECT FROM api_private.ai_disclosure d WHERE d.recipient=ai_runtime_dispatch.recipient)
       OR NOT app.jobs_authorize_dispatch(job_id,token) THEN RETURN false; END IF;
    SELECT units INTO amount FROM app.usage_reservations r WHERE r.ai_job_id=job_id AND r.status='reserved';
    IF amount IS NULL THEN RETURN false; END IF;
    SELECT * INTO STRICT j FROM app.ai_jobs WHERE id=job_id;
    IF j.kind='image_analysis' AND NOT policy.image_enabled THEN RETURN false; END IF;
    IF j.kind='purchase_fit' THEN
        PERFORM 1 FROM app.purchase_candidates c JOIN api_private.job_payloads p ON p.job_id=j.id
          JOIN api_private.image_uploads u ON u.id=c.image_id AND u.user_id=c.user_id AND u.purchase_id=c.id AND u.state='ready'
          WHERE c.id=(p.input->>'candidate_id')::uuid AND c.user_id=j.user_id AND c.status='considering' AND c.deleted_at IS NULL AND c.expires_at>clock_timestamp() FOR SHARE OF c;
        IF NOT FOUND THEN RETURN false; END IF;
    END IF;
    IF EXISTS(SELECT FROM api_private.ai_dispatch_receipts d WHERE d.job_id=j.id) THEN
        IF j.kind NOT IN('outfit_generation','purchase_fit') OR j.pricing_version IS DISTINCT FROM 'call-credits-v1' OR NOT EXISTS(SELECT FROM api_private.ai_dispatch_receipts d
            WHERE d.job_id=j.id AND d.provider_call=1 AND d.attempt=j.attempts
              AND d.telemetry->>'status'='outfit_json_invalid') THEN RETURN false; END IF;
        call_number := 2;
    END IF;
    IF j.kind IN('outfit_generation','purchase_fit') AND j.pricing_version='call-credits-v1' THEN amount := amount/2; END IF;
    IF coalesce((SELECT d.units FROM api_private.ai_daily_dispatch d WHERE d.day=current_day),0)+amount>policy.daily_global_units
      OR coalesce((SELECT sum(d.units) FROM api_private.ai_dispatch_receipts d JOIN app.ai_jobs q ON q.id=d.job_id
        WHERE q.user_id=j.user_id AND (d.dispatched_at AT TIME ZONE 'UTC')::date=current_day),0)+amount>policy.daily_user_units
      THEN RETURN false; END IF;
    INSERT INTO api_private.ai_dispatch_receipts(job_id,provider_call,attempt,units)
        VALUES(j.id,call_number,j.attempts,amount) ON CONFLICT DO NOTHING;
    IF NOT FOUND THEN RETURN false; END IF;
    INSERT INTO api_private.ai_daily_dispatch(day,units) VALUES(current_day,amount)
        ON CONFLICT(day) DO UPDATE SET units=api_private.ai_daily_dispatch.units+EXCLUDED.units;
    RETURN true;
END $$;


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
            'availability',g.availability,'archived',g.archived_at IS NOT NULL)),'[]'::jsonb)
            INTO items FROM (SELECT * FROM app.garments WHERE user_id=j.user_id AND deleted_at IS NULL
                ORDER BY id LIMIT 1001) g;
        IF jsonb_array_length(items)>1000 THEN RETURN NULL; END IF;
        IF j.kind='purchase_fit' THEN
            SELECT c.metadata||jsonb_build_object('id',c.id) INTO candidate FROM app.purchase_candidates c
             JOIN api_private.image_uploads u ON u.id=c.image_id AND u.user_id=c.user_id AND u.purchase_id=c.id AND u.state='ready'
             WHERE c.id=(payload->>'candidate_id')::uuid AND c.user_id=j.user_id AND c.deleted_at IS NULL AND c.status='considering' AND c.expires_at>clock_timestamp();
            IF candidate IS NULL THEN RETURN NULL; END IF;
            RETURN jsonb_build_object('garments',items,'purchase_candidate',candidate,'count',3);
        END IF;
        RETURN (payload - ARRAY['garments','user_id','owner','object_key','image_id']) || jsonb_build_object('garments',items);
    END IF;
    RETURN NULL;
END $$;

CREATE FUNCTION app.api_v1_purchase_fit(request jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE owner_id uuid:=auth.uid(); rid uuid:=gen_random_uuid(); candidate uuid; operation uuid; job uuid; code text;
BEGIN
 IF owner_id IS NULL THEN RETURN jsonb_build_object('error',jsonb_build_object('code','unauthorized','message','Sign in required','request_id',rid)); END IF;
 PERFORM 1 FROM app.profiles WHERE user_id=owner_id AND deleted_at IS NULL FOR SHARE;
 IF NOT FOUND THEN RETURN jsonb_build_object('error',jsonb_build_object('code','account_unavailable','message','Account unavailable','request_id',rid)); END IF;
 IF jsonb_typeof(request) IS DISTINCT FROM 'object' OR NOT request ?& ARRAY['operation_id','candidate_id'] OR request-ARRAY['operation_id','candidate_id']<>'{}'::jsonb THEN RAISE EXCEPTION USING ERRCODE='22023'; END IF;
 candidate:=(request->>'candidate_id')::uuid; operation:=(request->>'operation_id')::uuid;
 IF candidate IS NULL OR operation IS NULL THEN RAISE EXCEPTION USING ERRCODE='22023'; END IF;
 PERFORM 1 FROM app.purchase_candidates c JOIN api_private.image_uploads u ON u.id=c.image_id AND u.user_id=c.user_id AND u.purchase_id=c.id AND u.state='ready'
 WHERE c.id=candidate AND c.user_id=owner_id AND c.status='considering' AND c.deleted_at IS NULL AND c.expires_at>clock_timestamp() FOR SHARE OF c;
 IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='22023'; END IF;
 job:=app.jobs_enqueue(owner_id,operation,'purchase_fit',jsonb_build_object('candidate_id',candidate),1);
 RETURN jsonb_build_object('data',jsonb_build_object('job_id',job,'status',(SELECT status FROM app.ai_jobs WHERE id=job)),'request_id',rid);
EXCEPTION WHEN invalid_text_representation OR numeric_value_out_of_range OR invalid_parameter_value THEN
 code:=CASE SQLERRM WHEN 'AI disabled' THEN 'ai_disabled' WHEN 'AI quota exhausted' THEN 'quota_exceeded' WHEN 'AI consent required' THEN 'consent_required' ELSE 'validation_failed' END;
 RETURN jsonb_build_object('error',jsonb_build_object('code',code,'message','Request could not be accepted','request_id',rid));
END $$;
REVOKE ALL ON FUNCTION app.api_v1_purchase_fit(jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION app.api_v1_purchase_fit(jsonb) TO authenticated;

CREATE FUNCTION app.api_v1_purchase_fit_result(request jsonb) RETURNS jsonb
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
      'result',CASE WHEN j.status='succeeded' THEN p.result->'result' ELSE NULL END) INTO result
      FROM app.ai_jobs j JOIN api_private.job_payloads p ON p.job_id=j.id
      WHERE j.id=job AND j.user_id=owner_id AND j.kind='purchase_fit' AND j.deleted_at IS NULL;
    IF result IS NULL THEN RETURN jsonb_build_object('error',jsonb_build_object('code','not_found','message','Job unavailable','request_id',rid)); END IF;
    RETURN jsonb_build_object('data',result,'request_id',rid);
EXCEPTION WHEN invalid_text_representation OR invalid_parameter_value THEN
    RETURN jsonb_build_object('error',jsonb_build_object('code','validation_failed','message','Invalid request','request_id',rid));
WHEN OTHERS THEN RETURN jsonb_build_object('error',jsonb_build_object('code','internal_error','message','Request could not be completed','request_id',rid));
END $$;
REVOKE ALL ON FUNCTION app.api_v1_purchase_fit_result(jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION app.api_v1_purchase_fit_result(jsonb) TO authenticated;

CREATE OR REPLACE FUNCTION api_private.export_snapshot(owner_id uuid) RETURNS jsonb
LANGUAGE sql STABLE SET search_path = pg_catalog AS $$
SELECT jsonb_build_object('schema_version',1,'captured_at',statement_timestamp(),
'profiles', (SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY r.id),'[]'::jsonb) FROM
    (SELECT id, display_name, language, city, created_at FROM app.profiles WHERE user_id = owner_id AND deleted_at IS NULL) r),
'garments', (SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY r.id),'[]'::jsonb) FROM
    (SELECT id, name, category, subcategory, colors, pattern, seasons, formality, price_grosz::text AS price_grosz, currency, brand, purchased_on, availability, archived_at, estimated_prior_wears, tracking_start_date, created_at FROM app.garments WHERE user_id = owner_id AND deleted_at IS NULL) r),
'outfits', (SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY r.id),'[]'::jsonb) FROM
    (SELECT id, name, favorite, created_at FROM app.outfits WHERE user_id = owner_id AND deleted_at IS NULL) r),
'outfit_items', (SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY r.id),'[]'::jsonb) FROM
    (SELECT id, outfit_id, garment_id, position FROM app.outfit_items WHERE user_id = owner_id AND deleted_at IS NULL) r),
'wear_events', (SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY r.id),'[]'::jsonb) FROM
    (SELECT id, worn_on, timezone, source_outfit_id FROM app.wear_events WHERE user_id = owner_id AND deleted_at IS NULL) r),
'wear_event_items', (SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY r.id),'[]'::jsonb) FROM
    (SELECT id, wear_event_id, garment_id FROM app.wear_event_items WHERE user_id = owner_id AND deleted_at IS NULL) r),
'preferences', (SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY r.id),'[]'::jsonb) FROM
    (SELECT id, styles, colors, excluded_categories, notes FROM app.preferences WHERE user_id = owner_id AND deleted_at IS NULL) r),
'outfit_feedback', (SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY r.id),'[]'::jsonb) FROM
    (SELECT id, outfit_id, rating, reason FROM app.outfit_feedback WHERE user_id = owner_id AND deleted_at IS NULL) r),
'consent_events', (SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY r.id),'[]'::jsonb) FROM
    (SELECT id, purpose, policy_version, recipient, granted, created_at FROM app.consent_events WHERE user_id = owner_id AND deleted_at IS NULL) r),
'planned_outfits', (SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY r.id),'[]'::jsonb) FROM
    (SELECT id, outfit_id, planned_on, notes FROM app.planned_outfits WHERE user_id = owner_id AND deleted_at IS NULL) r),
'trips', (SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY r.id),'[]'::jsonb) FROM
    (SELECT id, destination, starts_on, ends_on, occasions FROM app.trips WHERE user_id = owner_id AND deleted_at IS NULL) r),
'trip_items', (SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY r.id),'[]'::jsonb) FROM
    (SELECT id, trip_id, garment_id, packed FROM app.trip_items WHERE user_id = owner_id AND deleted_at IS NULL) r),
'purchase_candidates', (SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY r.id),'[]'::jsonb) FROM
    (SELECT id, name, metadata, price_grosz::text AS price_grosz, image_id, expires_at, status, purchased_garment_id FROM app.purchase_candidates WHERE user_id = owner_id AND deleted_at IS NULL) r),
'subscription_entitlements', (SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY r.id),'[]'::jsonb) FROM
    (SELECT id, product_id, status, expires_at, environment FROM app.subscription_entitlements WHERE user_id = owner_id AND deleted_at IS NULL) r),
'support_requests', (SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY r.id),'[]'::jsonb) FROM
    (SELECT id, subject, message, status, created_at FROM app.support_requests WHERE user_id = owner_id AND deleted_at IS NULL) r),
'purchase_images', (SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY r.id),'[]'::jsonb) FROM
    (SELECT u.id,c.id AS candidate_id,'image/jpeg'::text AS content_type,u.id::text||'/original.jpg' AS object_key
       FROM app.purchase_candidates c JOIN api_private.image_uploads u ON u.id=c.image_id AND u.purchase_id=c.id AND u.user_id=c.user_id AND u.state='ready'
       WHERE c.user_id=owner_id AND c.status='considering' AND c.deleted_at IS NULL AND c.expires_at>statement_timestamp()) r),
'garment_images', (SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY r.id),'[]'::jsonb) FROM
    (SELECT id, garment_id, variant, content_type, object_key FROM app.garment_images WHERE user_id = owner_id AND deleted_at IS NULL AND status = 'ready') r));
$$;

CREATE OR REPLACE FUNCTION app.exports_command(request jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
DECLARE
    action text := request->>'action';
    owner_id uuid := (request->>'owner')::uuid;
    operation_id uuid := (request->>'id')::uuid;
    row api_private.data_exports%ROWTYPE;
BEGIN
    IF action = 'sweep' THEN
        UPDATE api_private.data_exports e SET snapshot = NULL
        WHERE snapshot IS NOT NULL AND (expires_at <= clock_timestamp() OR NOT EXISTS (
            SELECT FROM app.profiles p WHERE p.user_id = e.user_id AND p.deleted_at IS NULL));
        RETURN 'true'::jsonb;
    END IF;
    IF owner_id IS NULL OR operation_id IS NULL THEN RETURN 'null'::jsonb; END IF;
    -- Serialize requests per account; bound retained snapshots and prevent races.
    PERFORM 1 FROM app.profiles WHERE user_id = owner_id AND deleted_at IS NULL FOR UPDATE;
    IF NOT FOUND THEN RETURN 'null'::jsonb; END IF;
    IF action = 'prepare' AND NOT EXISTS (SELECT FROM api_private.data_exports WHERE id = operation_id) THEN
        IF EXISTS (SELECT FROM api_private.data_exports WHERE user_id = owner_id
            AND expires_at > clock_timestamp()) THEN RAISE EXCEPTION 'export_in_progress'; END IF;
        INSERT INTO api_private.data_exports(id,user_id,snapshot)
        VALUES(operation_id,owner_id,api_private.export_snapshot(owner_id));
    END IF;
    SELECT * INTO row FROM api_private.data_exports WHERE id = operation_id AND user_id = owner_id;
    IF NOT FOUND OR row.expires_at <= clock_timestamp() OR row.snapshot IS NULL THEN RETURN 'null'::jsonb; END IF;
    IF action = 'prepare' OR action = 'check' THEN
        RETURN jsonb_build_object('id',row.id,'expires_at',row.expires_at);
    ELSIF action = 'read' THEN
        RETURN jsonb_build_object('id',row.id,'expires_at',row.expires_at,'snapshot',row.snapshot);
    ELSIF action = 'image' THEN
        -- Revalidate each snapshot reference against current metadata before IO.
        RETURN to_jsonb(EXISTS (SELECT FROM app.garment_images i JOIN app.garments g
            ON g.user_id = i.user_id AND g.id = i.garment_id
            WHERE i.user_id = owner_id AND i.id = (request->>'image')::uuid
            AND i.object_key = request->>'key' AND i.status = 'ready'
            AND i.deleted_at IS NULL AND g.deleted_at IS NULL) OR EXISTS (
            SELECT FROM app.purchase_candidates c JOIN api_private.image_uploads u ON u.id=c.image_id AND u.purchase_id=c.id AND u.user_id=c.user_id
            WHERE c.user_id=owner_id AND u.id=(request->>'image')::uuid AND request->>'key'=u.id::text||'/original.jpg'
              AND u.state='ready' AND c.deleted_at IS NULL AND c.status='considering' AND c.expires_at>clock_timestamp()));
    END IF;
    RETURN 'null'::jsonb;
END $$;
