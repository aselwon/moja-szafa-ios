-- Durable object inventory deliberately survives garment/profile deletion.
-- This is server-only; identity must come from verified gateway authentication.
CREATE TABLE api_private.image_uploads (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id uuid NOT NULL,
    garment_id uuid NOT NULL,
    operation_id uuid NOT NULL,
    state text NOT NULL DEFAULT 'pending' CHECK (state IN ('pending','ready','deleting')),
    digest text,
    expires_at timestamptz NOT NULL DEFAULT now() + interval '10 minutes',
    swept_at timestamptz,
    UNIQUE(user_id, operation_id)
);
REVOKE ALL ON api_private.image_uploads FROM PUBLIC, anon, authenticated;
CREATE INDEX image_uploads_cleanup ON api_private.image_uploads (state, swept_at, expires_at);

CREATE FUNCTION app.images_command(request jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
DECLARE
    action text := request->>'action';
    owner_id uuid := (request->>'owner')::uuid;
    item api_private.image_uploads%ROWTYPE;
    result jsonb;
BEGIN
    IF action = 'sweep' THEN
        -- Retain tombstones: retries and late writers cannot resurrect metadata.
        UPDATE api_private.image_uploads u SET state = 'deleting'
        WHERE state <> 'deleting' AND (
            (state = 'pending' AND expires_at <= clock_timestamp()) OR
            NOT EXISTS (SELECT FROM app.garments g JOIN app.profiles p ON p.user_id = g.user_id
                WHERE g.id = u.garment_id AND g.user_id = u.user_id
                AND g.deleted_at IS NULL AND p.deleted_at IS NULL) OR
            (state = 'ready' AND (SELECT count(*) FROM app.garment_images i
                WHERE i.object_key IN (u.id::text || '/original.png',u.id::text || '/thumbnail.png')
                AND i.deleted_at IS NULL AND i.status = 'ready') <> 2));
        SELECT coalesce(jsonb_agg(jsonb_build_object('id',q.id,
            'original_key',q.id::text || '/original.png','thumbnail_key',q.id::text || '/thumbnail.png')), '[]'::jsonb)
        INTO result FROM (SELECT id FROM api_private.image_uploads WHERE state = 'deleting'
            ORDER BY swept_at NULLS FIRST, id LIMIT 100) q;
        RETURN result;
    ELSIF action = 'swept' THEN
        UPDATE api_private.image_uploads SET swept_at = clock_timestamp()
            WHERE id = (request->>'id')::uuid AND state = 'deleting';
        RETURN '{}'::jsonb;
    END IF;
    -- Serialize with deletion of the owning account and garment through commit.
    PERFORM 1 FROM app.profiles WHERE user_id = owner_id AND deleted_at IS NULL FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Image access denied' USING ERRCODE = '42501'; END IF;
    IF action = 'begin' THEN
        PERFORM 1 FROM app.garments WHERE id = (request->>'garment')::uuid
            AND user_id = owner_id AND deleted_at IS NULL FOR UPDATE;
        IF NOT FOUND THEN RAISE EXCEPTION 'Image access denied' USING ERRCODE = '42501'; END IF;
        INSERT INTO api_private.image_uploads(user_id,garment_id,operation_id)
            VALUES(owner_id,(request->>'garment')::uuid,(request->>'operation')::uuid)
            ON CONFLICT(user_id,operation_id) DO NOTHING;
        SELECT * INTO item FROM api_private.image_uploads
            WHERE user_id = owner_id AND operation_id = (request->>'operation')::uuid FOR UPDATE;
        IF item.garment_id <> (request->>'garment')::uuid THEN
            RAISE EXCEPTION 'Operation conflict' USING ERRCODE = '22023';
        END IF;
    ELSE
        SELECT * INTO item FROM api_private.image_uploads
            WHERE id = (request->>'id')::uuid AND user_id = owner_id FOR UPDATE;
        IF NOT FOUND THEN RAISE EXCEPTION 'Image access denied' USING ERRCODE = '42501'; END IF;
        PERFORM 1 FROM app.garments WHERE id = item.garment_id AND user_id = owner_id AND deleted_at IS NULL FOR UPDATE;
        IF NOT FOUND THEN RAISE EXCEPTION 'Image access denied' USING ERRCODE = '42501'; END IF;
    END IF;
    IF item.state = 'deleting' OR (item.state = 'pending' AND item.expires_at <= clock_timestamp()) THEN
        RAISE EXCEPTION 'Image expired' USING ERRCODE = '42501';
    END IF;
    IF action = 'upload' THEN
        IF coalesce(request->>'digest','') !~ '^[0-9a-f]{64}$' THEN RAISE EXCEPTION 'Invalid digest'; END IF;
        IF item.digest IS NOT NULL AND item.digest <> request->>'digest' THEN
            RAISE EXCEPTION 'Upload conflict' USING ERRCODE = '22023';
        END IF;
        UPDATE api_private.image_uploads SET digest = request->>'digest' WHERE id = item.id;
    ELSIF action = 'finish' AND item.state = 'pending' THEN
        IF item.digest IS NULL OR coalesce((request->>'original_bytes')::bigint,0) NOT BETWEEN 1 AND 20971520
            OR coalesce((request->>'thumbnail_bytes')::bigint,0) NOT BETWEEN 1 AND 20971520
            OR NOT request ?& ARRAY['original_bytes','thumbnail_bytes'] THEN RAISE EXCEPTION 'Invalid image'; END IF;
        -- Existing live variants are not silently replaced; replacement is a
        -- separate user operation. Conflicts leave inventory for orphan cleanup.
        INSERT INTO app.garment_images(user_id,garment_id,variant,object_key,status,content_type,byte_count)
        VALUES(owner_id,item.garment_id,'original',item.id::text || '/original.png','ready','image/png',(request->>'original_bytes')::bigint),
              (owner_id,item.garment_id,'thumbnail',item.id::text || '/thumbnail.png','ready','image/png',(request->>'thumbnail_bytes')::bigint);
        UPDATE api_private.image_uploads SET state = 'ready' WHERE id = item.id;
        item.state := 'ready';
    ELSIF action = 'read' THEN
        IF item.state <> 'ready' OR (SELECT count(*) FROM app.garment_images
            WHERE user_id = owner_id AND garment_id = item.garment_id AND status = 'ready' AND deleted_at IS NULL
            AND object_key IN (item.id::text || '/original.png',item.id::text || '/thumbnail.png')) <> 2 THEN
            RAISE EXCEPTION 'Image access denied' USING ERRCODE = '42501';
        END IF;
    ELSIF action NOT IN ('begin','finish') THEN
        RAISE EXCEPTION 'Invalid action' USING ERRCODE = '22023';
    END IF;
    RETURN jsonb_build_object('id',item.id,'state',item.state,
        'original_key',item.id::text || '/original.png','thumbnail_key',item.id::text || '/thumbnail.png');
END $$;
REVOKE ALL ON FUNCTION app.images_command(jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION app.images_command(jsonb) TO service_role;
