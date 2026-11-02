-- Private durable upload ledger intentionally survives garment/account deletion.
-- No signed capabilities, EXIF or raw bytes are stored in database metadata.
CREATE TABLE api_private.image_uploads (
    id uuid PRIMARY KEY,
    user_id uuid NOT NULL,
    garment_id uuid NOT NULL,
    state text NOT NULL DEFAULT 'pending' CHECK (state IN ('pending','processing','ready','retired')),
    fence uuid,
    expires_at timestamptz NOT NULL DEFAULT (clock_timestamp() + interval '15 minutes'),
    next_cleanup_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE INDEX image_uploads_cleanup ON api_private.image_uploads(state, next_cleanup_at, expires_at);
REVOKE ALL ON api_private.image_uploads FROM PUBLIC, anon, authenticated;

CREATE FUNCTION app.images_command(request jsonb) RETURNS jsonb
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
        WITH candidates AS (
            SELECT u.id FROM api_private.image_uploads u
            WHERE u.next_cleanup_at <= clock_timestamp() AND (
                u.state = 'retired' OR
                (u.state IN ('pending','processing') AND u.expires_at <= clock_timestamp()) OR
                NOT EXISTS (SELECT FROM app.profiles p WHERE p.user_id = u.user_id AND p.deleted_at IS NULL) OR
                NOT EXISTS (SELECT FROM app.garments g WHERE g.id = u.garment_id AND g.user_id = u.user_id AND g.deleted_at IS NULL) OR
                (u.state = 'ready' AND (SELECT count(*) FROM app.garment_images i
                    WHERE i.user_id = u.user_id AND i.garment_id = u.garment_id AND i.deleted_at IS NULL
                    AND i.status = 'ready' AND i.object_key IN (u.id::text || '/original.jpg', u.id::text || '/thumbnail.jpg')) <> 2)
            ) ORDER BY u.next_cleanup_at,u.id FOR UPDATE SKIP LOCKED LIMIT 100
        ), retired AS (
            UPDATE api_private.image_uploads u SET state = 'retired', fence = NULL
            FROM candidates c WHERE u.id = c.id RETURNING u.id
        ) SELECT coalesce(jsonb_agg(jsonb_build_object('id',id)), '[]'::jsonb) INTO result FROM retired;
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
REVOKE ALL ON FUNCTION app.images_command(jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION app.images_command(jsonb) TO service_role;
