-- Private expiring analysis inputs do not become wardrobe items before confirmation.
CREATE TABLE api_private.recognition_drafts (
    id uuid PRIMARY KEY,
    user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    expires_at timestamptz NOT NULL DEFAULT clock_timestamp() + interval '24 hours',
    image_id uuid,
    deleted_at timestamptz
);
REVOKE ALL ON api_private.recognition_drafts FROM PUBLIC,anon,authenticated,service_role;
ALTER TABLE api_private.image_uploads ADD COLUMN recognition_id uuid;
ALTER TABLE api_private.image_uploads DROP CONSTRAINT image_one_parent;
ALTER TABLE api_private.image_uploads ADD CONSTRAINT image_one_parent
    CHECK (num_nonnulls(garment_id,purchase_id,recognition_id)=1);
CREATE UNIQUE INDEX recognition_single_image ON api_private.image_uploads(user_id,recognition_id)
    WHERE recognition_id IS NOT NULL AND state <> 'retired';

CREATE FUNCTION app.recognition_images_command(request jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE action text:=request->>'action'; owner_id uuid:=(request->>'owner')::uuid;
 image uuid:=(request->>'id')::uuid; draft uuid:=(request->>'garment')::uuid;
 row api_private.image_uploads%ROWTYPE; d api_private.recognition_drafts%ROWTYPE;
BEGIN
 IF owner_id IS NULL OR image IS NULL OR action NOT IN ('prepare','claim','finish','read')
    OR coalesce((request->>'has_cleaned')::boolean,false) THEN RETURN NULL; END IF;
 PERFORM 1 FROM app.profiles WHERE user_id=owner_id AND deleted_at IS NULL FOR SHARE;
 IF NOT FOUND THEN RETURN NULL; END IF;
 IF action='prepare' THEN
  IF draft IS NULL THEN RETURN NULL; END IF;
  INSERT INTO api_private.recognition_drafts(id,user_id) VALUES(draft,owner_id) ON CONFLICT DO NOTHING;
 ELSE
  SELECT recognition_id INTO draft FROM api_private.image_uploads WHERE id=image AND user_id=owner_id;
 END IF;
 SELECT * INTO d FROM api_private.recognition_drafts WHERE id=draft AND user_id=owner_id FOR UPDATE;
 IF NOT FOUND OR d.deleted_at IS NOT NULL OR d.expires_at<=clock_timestamp() THEN RETURN NULL; END IF;
 IF action='prepare' THEN
  -- A replacement gets a fresh namespace; a delayed old writer cannot publish it.
  UPDATE api_private.image_uploads SET state='retired',fence=NULL
    WHERE user_id=owner_id AND recognition_id=draft AND state IN ('pending','processing') AND expires_at<=clock_timestamp();
  INSERT INTO api_private.image_uploads(id,user_id,garment_id,recognition_id)
    VALUES(image,owner_id,NULL,draft) ON CONFLICT DO NOTHING;
 END IF;
 SELECT * INTO row FROM api_private.image_uploads WHERE id=image AND user_id=owner_id AND recognition_id=draft FOR UPDATE;
 IF NOT FOUND OR row.state='retired' THEN RETURN NULL; END IF;
 IF action='prepare' THEN
  RETURN jsonb_build_object('id',row.id);
 ELSIF action='claim' THEN
  IF row.state='ready' THEN RETURN jsonb_build_object('state','ready'); END IF;
  IF row.state<>'pending' OR row.expires_at<=clock_timestamp() THEN RETURN NULL; END IF;
  UPDATE api_private.image_uploads SET state='processing',fence=gen_random_uuid(),expires_at=clock_timestamp()+interval '60 seconds'
    WHERE id=image RETURNING * INTO row;
  RETURN jsonb_build_object('state',row.state,'fence',row.fence);
 ELSIF action='finish' THEN
  IF row.state<>'processing' OR row.fence IS DISTINCT FROM (request->>'fence')::uuid OR row.expires_at<=clock_timestamp() THEN RETURN NULL; END IF;
  UPDATE api_private.image_uploads SET state='ready',fence=NULL WHERE id=image;
  UPDATE api_private.recognition_drafts SET image_id=image WHERE id=draft;
  RETURN 'true'::jsonb;
 ELSIF action='read' THEN
  RETURN to_jsonb(row.state='ready' AND d.image_id=image AND request->>'variant' IN ('original','thumbnail'));
 END IF;
 RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION app.recognition_images_command(jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION app.recognition_images_command(jsonb) TO service_role;

-- Extend the existing shared sweep; retain expired-upload retry and paired-image behavior.
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
                (u.garment_id IS NOT NULL AND NOT EXISTS (SELECT FROM app.garments g WHERE g.id = u.garment_id AND g.user_id = u.user_id AND g.deleted_at IS NULL)) OR
                (u.purchase_id IS NOT NULL AND NOT EXISTS (SELECT FROM app.purchase_candidates c WHERE c.id=u.purchase_id AND c.user_id=u.user_id AND c.deleted_at IS NULL AND c.status='considering' AND c.expires_at>clock_timestamp())) OR
                (u.recognition_id IS NOT NULL AND NOT EXISTS (SELECT FROM api_private.recognition_drafts d WHERE d.id=u.recognition_id AND d.user_id=u.user_id AND d.deleted_at IS NULL AND d.expires_at>clock_timestamp())) OR
                (u.garment_id IS NOT NULL AND u.state = 'ready' AND (SELECT count(*) FROM app.garment_images i
                    WHERE i.user_id = u.user_id AND i.garment_id = u.garment_id AND i.deleted_at IS NULL
                    AND i.status = 'ready' AND i.object_key IN (u.id::text || '/original.jpg', u.id::text || '/thumbnail.jpg', u.id::text || '/cleaned.png')) <> (CASE WHEN u.has_cleaned THEN 3 ELSE 2 END))

            ) ORDER BY u.next_cleanup_at,u.id FOR UPDATE SKIP LOCKED LIMIT 100
        LOOP
            IF EXISTS (SELECT FROM api_private.image_uploads u WHERE u.id=row.id AND (
                u.state = 'retired' OR
                (u.state IN ('pending','processing') AND u.expires_at <= clock_timestamp()) OR
                NOT EXISTS (SELECT FROM app.profiles p WHERE p.user_id = u.user_id AND p.deleted_at IS NULL) OR
                (u.garment_id IS NOT NULL AND NOT EXISTS (SELECT FROM app.garments g WHERE g.id = u.garment_id AND g.user_id = u.user_id AND g.deleted_at IS NULL)) OR
                (u.purchase_id IS NOT NULL AND NOT EXISTS (SELECT FROM app.purchase_candidates c WHERE c.id=u.purchase_id AND c.user_id=u.user_id AND c.deleted_at IS NULL AND c.status='considering' AND c.expires_at>clock_timestamp())) OR
                (u.recognition_id IS NOT NULL AND NOT EXISTS (SELECT FROM api_private.recognition_drafts d WHERE d.id=u.recognition_id AND d.user_id=u.user_id AND d.deleted_at IS NULL AND d.expires_at>clock_timestamp())) OR
                (u.garment_id IS NOT NULL AND u.state = 'ready' AND (SELECT count(*) FROM app.garment_images i
                    WHERE i.user_id = u.user_id AND i.garment_id = u.garment_id AND i.deleted_at IS NULL
                    AND i.status = 'ready' AND i.object_key IN (u.id::text || '/original.jpg', u.id::text || '/thumbnail.jpg', u.id::text || '/cleaned.png')) <> (CASE WHEN u.has_cleaned THEN 3 ELSE 2 END))

            )) THEN
                UPDATE api_private.image_uploads SET state='retired',fence=NULL WHERE id=row.id;
                result := result || jsonb_build_array(jsonb_build_object('id',row.id));
            END IF;
        END LOOP;
        RETURN result;
    ELSIF action = 'cleaned' THEN
        DELETE FROM app.garment_images i USING api_private.image_uploads u
        WHERE u.id = operation_id AND u.state = 'retired'
          AND i.object_key IN (u.id::text || '/original.jpg', u.id::text || '/thumbnail.jpg', u.id::text || '/cleaned.png');
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
        INSERT INTO api_private.image_uploads(id,user_id,garment_id,has_cleaned)
        VALUES(operation_id,owner_id,garment,COALESCE((request->>'has_cleaned')::boolean,false))
        ON CONFLICT DO NOTHING;
    END IF;
    SELECT * INTO row FROM api_private.image_uploads WHERE id = operation_id AND user_id = owner_id FOR UPDATE;
    IF NOT FOUND OR (row.state = 'retired' AND action <> 'prepare') THEN RETURN 'null'::jsonb; END IF;
    PERFORM 1 FROM app.garments WHERE id = row.garment_id AND user_id = owner_id AND deleted_at IS NULL FOR SHARE;
    IF NOT FOUND THEN RETURN 'null'::jsonb; END IF;
    IF action = 'prepare' THEN
        IF row.has_cleaned IS DISTINCT FROM COALESCE((request->>'has_cleaned')::boolean,false)
           OR row.garment_id <> garment THEN
            RETURN 'null'::jsonb;
        END IF;
        IF row.state = 'retired' OR (row.state <> 'ready' AND row.expires_at <= clock_timestamp()) THEN
            -- Retire the old namespace before telling the client to allocate a new
            -- image ID. A delayed writer cannot publish with the old fence and
            -- cleanup of old bytes cannot remove the new upload's distinct keys.
            UPDATE api_private.image_uploads SET state='retired',fence=NULL,next_cleanup_at=clock_timestamp() WHERE id=row.id;
            DELETE FROM app.garment_images WHERE user_id=owner_id AND garment_id=row.garment_id
                AND object_key IN (row.id::text||'/original.jpg',row.id::text||'/thumbnail.jpg',row.id::text||'/cleaned.png');
            RETURN jsonb_build_object('id',row.id,'expired',true);
        END IF;
        RETURN jsonb_build_object('id',row.id);
    ELSIF action = 'claim' THEN
        IF row.state = 'ready' THEN RETURN jsonb_build_object('state','ready','has_cleaned',row.has_cleaned); END IF;
        IF row.state <> 'pending' OR row.expires_at <= clock_timestamp() THEN RETURN 'null'::jsonb; END IF;
        UPDATE api_private.image_uploads SET state = 'processing', fence = gen_random_uuid(),
            expires_at = clock_timestamp() + interval '60 seconds' WHERE id = row.id RETURNING * INTO row;
        RETURN jsonb_build_object('state',row.state,'fence',row.fence,'has_cleaned',row.has_cleaned);
    ELSIF action = 'finish' THEN
        IF row.state <> 'processing' OR row.fence IS DISTINCT FROM (request->>'fence')::uuid
           OR row.expires_at <= clock_timestamp() THEN RETURN 'null'::jsonb; END IF;
        -- An upload never silently replaces another operation's image variants.
        INSERT INTO app.garment_images(user_id,garment_id,variant,object_key,status,content_type)
        VALUES(owner_id,row.garment_id,'original',row.id::text || '/original.jpg','ready','image/jpeg'),
              (owner_id,row.garment_id,'thumbnail',row.id::text || '/thumbnail.jpg','ready','image/jpeg');
        IF row.has_cleaned THEN
            INSERT INTO app.garment_images(user_id,garment_id,variant,object_key,status,content_type)
            VALUES(owner_id,row.garment_id,'cleaned',row.id::text || '/cleaned.png','ready','image/png');
        END IF;
        UPDATE api_private.image_uploads SET state = 'ready',fence = NULL WHERE id = row.id;
        RETURN 'true'::jsonb;
    ELSIF action = 'read' THEN
        RETURN to_jsonb(row.state = 'ready'
            AND (COALESCE(request->>'variant','thumbnail') IN ('original','thumbnail') OR (request->>'variant'='cleaned' AND row.has_cleaned)) AND (SELECT count(*) FROM app.garment_images i
            WHERE i.user_id = owner_id AND i.garment_id = row.garment_id AND i.deleted_at IS NULL
              AND i.status = 'ready' AND i.object_key IN (row.id::text || '/original.jpg',row.id::text || '/thumbnail.jpg',row.id::text || '/cleaned.png')) = (CASE WHEN row.has_cleaned THEN 3 ELSE 2 END));
    END IF;
    RETURN 'null'::jsonb;
END $$;

CREATE FUNCTION app.api_v1_recognition(request jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE owner_id uuid:=auth.uid(); rid uuid:=gen_random_uuid(); action text:=request->>'action';
 draft uuid; image uuid; operation uuid; job uuid; d api_private.recognition_drafts%ROWTYPE; result jsonb; code text;
BEGIN
 IF owner_id IS NULL THEN RETURN jsonb_build_object('error',jsonb_build_object('code','unauthorized','message','Sign in required','request_id',rid)); END IF;
 PERFORM 1 FROM app.profiles WHERE user_id=owner_id AND deleted_at IS NULL FOR SHARE;
 IF NOT FOUND THEN RETURN jsonb_build_object('error',jsonb_build_object('code','account_unavailable','message','Account unavailable','request_id',rid)); END IF;
 IF jsonb_typeof(request) IS DISTINCT FROM 'object' OR action IS NULL OR action NOT IN ('enqueue','result','discard') THEN
  RAISE EXCEPTION 'Invalid request' USING ERRCODE='22023'; END IF;
 IF (action='enqueue' AND (NOT request ?& ARRAY['action','draft_id','image_id','operation_id'] OR request-ARRAY['action','draft_id','image_id','operation_id']<>'{}'::jsonb))
 OR (action='result' AND (NOT request ?& ARRAY['action','draft_id','image_id','job_id'] OR request-ARRAY['action','draft_id','image_id','job_id']<>'{}'::jsonb))
 OR (action='discard' AND (NOT request ?& ARRAY['action','draft_id'] OR request-ARRAY['action','draft_id']<>'{}'::jsonb)) THEN
  RAISE EXCEPTION 'Invalid request' USING ERRCODE='22023'; END IF;
 draft:=(request->>'draft_id')::uuid;
 IF draft IS NULL THEN RAISE EXCEPTION 'Invalid request' USING ERRCODE='22023'; END IF;
 SELECT * INTO d FROM api_private.recognition_drafts WHERE id=draft AND user_id=owner_id FOR UPDATE;
 IF NOT FOUND THEN RETURN jsonb_build_object('error',jsonb_build_object('code','not_found','message','Draft unavailable','request_id',rid)); END IF;
 IF action='discard' THEN
  UPDATE api_private.recognition_drafts SET deleted_at=coalesce(deleted_at,clock_timestamp()) WHERE id=draft;
  UPDATE api_private.image_uploads SET state='retired',fence=NULL,next_cleanup_at=clock_timestamp() WHERE recognition_id=draft AND user_id=owner_id;
  UPDATE app.ai_jobs j SET status='cancelled',lease_token=NULL,lease_expires_at=NULL,finished_at=clock_timestamp(),error_code='draft_discarded'
   WHERE j.user_id=owner_id AND j.kind='image_analysis' AND j.status IN ('queued','running')
    AND EXISTS(SELECT FROM api_private.job_payloads p WHERE p.job_id=j.id AND p.input->>'draft_id'=draft::text);
  UPDATE app.usage_reservations r SET status='released' WHERE r.user_id=owner_id AND r.status='reserved'
   AND EXISTS(SELECT FROM app.ai_jobs j WHERE j.id=r.ai_job_id AND j.status='cancelled');
  RETURN jsonb_build_object('data',jsonb_build_object('discarded',true),'request_id',rid);
 END IF;
 image:=(request->>'image_id')::uuid;
 IF image IS NULL OR d.image_id IS DISTINCT FROM image OR d.deleted_at IS NOT NULL OR d.expires_at<=clock_timestamp()
 OR NOT EXISTS(SELECT FROM api_private.image_uploads u WHERE u.id=image AND u.user_id=owner_id AND u.recognition_id=draft AND u.state='ready') THEN
  RETURN jsonb_build_object('error',jsonb_build_object('code','not_found','message','Draft unavailable','request_id',rid)); END IF;
 IF action='enqueue' THEN
  operation:=(request->>'operation_id')::uuid;
  IF operation IS NULL THEN RAISE EXCEPTION 'Invalid request' USING ERRCODE='22023'; END IF;
  job:=app.jobs_enqueue(owner_id,operation,'image_analysis',jsonb_build_object('draft_id',draft,'image_id',image),1);
  result:=jsonb_build_object('job_id',job,'draft_id',draft,'image_id',image,'status',(SELECT status FROM app.ai_jobs WHERE id=job));
 ELSE
  job:=(request->>'job_id')::uuid;
  IF job IS NULL THEN RAISE EXCEPTION 'Invalid request' USING ERRCODE='22023'; END IF;
  SELECT jsonb_build_object('job_id',j.id,'draft_id',draft,'image_id',image,'status',j.status,'error_code',j.error_code,
   'result',CASE WHEN j.status='succeeded' THEN p.result->'result' ELSE NULL END) INTO result
   FROM app.ai_jobs j JOIN api_private.job_payloads p ON p.job_id=j.id
   WHERE j.id=job AND j.user_id=owner_id AND j.kind='image_analysis' AND j.deleted_at IS NULL
    AND p.input->>'draft_id'=draft::text AND p.input->>'image_id'=image::text;
  IF result IS NULL THEN RETURN jsonb_build_object('error',jsonb_build_object('code','not_found','message','Job unavailable','request_id',rid)); END IF;
 END IF;
 RETURN jsonb_build_object('data',result,'request_id',rid);
EXCEPTION WHEN invalid_text_representation OR invalid_parameter_value THEN
 code:=CASE SQLERRM WHEN 'AI disabled' THEN 'ai_disabled' WHEN 'AI quota exhausted' THEN 'quota_exceeded'
  WHEN 'AI consent required' THEN 'consent_required' ELSE 'validation_failed' END;
 RETURN jsonb_build_object('error',jsonb_build_object('code',code,'message','Request could not be accepted','request_id',rid));
END $$;
REVOKE ALL ON FUNCTION app.api_v1_recognition(jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION app.api_v1_recognition(jsonb) TO authenticated;

-- Recheck the draft before every external dispatch, including retries after expiry.
ALTER FUNCTION app.jobs_authorize_dispatch(uuid,uuid) RENAME TO jobs_authorize_dispatch_before_recognition;
REVOKE ALL ON FUNCTION app.jobs_authorize_dispatch_before_recognition(uuid,uuid) FROM PUBLIC,anon,authenticated,service_role;
CREATE FUNCTION app.jobs_authorize_dispatch(job_id uuid,token uuid) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE j app.ai_jobs%ROWTYPE; payload jsonb;
BEGIN
 IF NOT app.jobs_authorize_dispatch_before_recognition(job_id,token) THEN RETURN false; END IF;
 SELECT * INTO j FROM app.ai_jobs WHERE id=job_id;
 SELECT input INTO payload FROM api_private.job_payloads p WHERE p.job_id=j.id;
 IF j.kind='image_analysis' AND payload ? 'draft_id' AND NOT EXISTS(
  SELECT FROM api_private.recognition_drafts d JOIN api_private.image_uploads u ON u.id=d.image_id AND u.recognition_id=d.id AND u.user_id=d.user_id
  WHERE d.id=(payload->>'draft_id')::uuid AND d.user_id=j.user_id AND d.image_id=(payload->>'image_id')::uuid
   AND d.deleted_at IS NULL AND d.expires_at>clock_timestamp() AND u.state='ready') THEN
  UPDATE app.ai_jobs SET status='cancelled',lease_token=NULL,lease_expires_at=NULL,finished_at=clock_timestamp(),error_code='draft_unavailable' WHERE id=job_id;
  UPDATE app.usage_reservations SET status='released' WHERE ai_job_id=job_id AND status='reserved';
  RETURN false;
 END IF;
 RETURN true;
END $$;
REVOKE ALL ON FUNCTION app.jobs_authorize_dispatch(uuid,uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION app.jobs_authorize_dispatch(uuid,uuid) TO service_role;

CREATE OR REPLACE FUNCTION app.ai_runtime_input(job_id uuid,token uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE j app.ai_jobs%ROWTYPE; payload jsonb; items jsonb; image_key text; candidate jsonb;
BEGIN
    IF NOT app.jobs_authorize_dispatch(job_id,token) THEN RETURN NULL; END IF;
    SELECT * INTO STRICT j FROM app.ai_jobs WHERE id=job_id;
    SELECT input INTO payload FROM api_private.job_payloads WHERE job_payloads.job_id=j.id;
    IF j.kind='image_analysis' THEN
        IF payload ? 'draft_id' THEN
            SELECT u.id::text || '/thumbnail.jpg' INTO image_key
            FROM api_private.recognition_drafts d JOIN api_private.image_uploads u
              ON u.id=d.image_id AND u.recognition_id=d.id AND u.user_id=d.user_id AND u.state='ready'
            WHERE d.id=(payload->>'draft_id')::uuid AND d.user_id=j.user_id
              AND d.image_id=(payload->>'image_id')::uuid AND d.deleted_at IS NULL AND d.expires_at>clock_timestamp();
        ELSE
        SELECT i.object_key INTO image_key FROM app.garment_images i
            JOIN api_private.image_uploads u ON i.object_key=u.id::text || '/thumbnail.jpg' AND u.user_id=i.user_id AND u.state='ready'
            JOIN app.garments g
            ON g.user_id=i.user_id AND g.id=i.garment_id
            WHERE u.id=(payload->>'image_id')::uuid AND i.user_id=j.user_id AND i.status='ready'
              AND i.deleted_at IS NULL AND g.deleted_at IS NULL AND i.variant='thumbnail';
        END IF;
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
