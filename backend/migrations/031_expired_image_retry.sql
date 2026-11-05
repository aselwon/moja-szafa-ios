-- Expired upload attempts get a new namespace; garment operation identity stays stable.
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
                    AND i.status = 'ready' AND i.object_key IN (u.id::text || '/original.jpg', u.id::text || '/thumbnail.jpg', u.id::text || '/cleaned.png')) <> (CASE WHEN u.has_cleaned THEN 3 ELSE 2 END))

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
