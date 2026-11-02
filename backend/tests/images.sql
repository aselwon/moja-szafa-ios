BEGIN;
CREATE FUNCTION pg_temp.check_image(ok boolean) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF ok IS DISTINCT FROM true THEN RAISE EXCEPTION 'Image assertion failed'; END IF; END $$;
CREATE FUNCTION pg_temp.image_denied(body jsonb) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    BEGIN PERFORM app.images_command(body);
    EXCEPTION WHEN insufficient_privilege THEN RETURN; END;
    RAISE EXCEPTION 'Expected denial';
END $$;
INSERT INTO auth.users VALUES ('10000000-0000-0000-0000-000000000001'),('10000000-0000-0000-0000-000000000002');
INSERT INTO app.profiles(id,user_id) SELECT id,id FROM auth.users WHERE id::text LIKE '10000000%';
INSERT INTO app.garments(id,user_id,name,category) VALUES
('20000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000001','Fixture','top');
DO $$
DECLARE
    owner_id text := '10000000-0000-0000-0000-000000000001';
    other_id text := '10000000-0000-0000-0000-000000000002';
    garment text := '20000000-0000-0000-0000-000000000001';
    request jsonb;
    first jsonb;
    second jsonb;
    image_id text;
BEGIN
    request := jsonb_build_object('action','begin','owner',owner_id,'garment',garment,'operation',gen_random_uuid());
    PERFORM pg_temp.image_denied(request || jsonb_build_object('owner',other_id));
    first := app.images_command(request);
    PERFORM pg_temp.check_image(first = app.images_command(request));
    image_id := first->>'id';
    PERFORM pg_temp.image_denied(jsonb_build_object('action','read','owner',owner_id,'id',image_id));
    PERFORM pg_temp.image_denied(jsonb_build_object('action','upload','owner',other_id,'id',image_id));
    PERFORM app.images_command(jsonb_build_object('action','upload','owner',owner_id,'id',image_id,'digest',repeat('a',64)));
    BEGIN
        PERFORM app.images_command(jsonb_build_object('action','upload','owner',owner_id,'id',image_id,'digest',repeat('b',64)));
        RAISE EXCEPTION 'Expected digest conflict';
    EXCEPTION WHEN invalid_parameter_value THEN NULL; END;
    request := jsonb_build_object('action','finish','owner',owner_id,'id',image_id,'original_bytes',120,'thumbnail_bytes',50);
    first := app.images_command(request);
    PERFORM pg_temp.check_image(first = app.images_command(request));
    PERFORM pg_temp.check_image((SELECT count(*) = 2 FROM app.garment_images WHERE garment_id = garment::uuid));
    PERFORM app.images_command(jsonb_build_object('action','read','owner',owner_id,'id',image_id));
    PERFORM pg_temp.image_denied(jsonb_build_object('action','read','owner',other_id,'id',image_id));
    second := app.images_command(jsonb_build_object('action','begin','owner',owner_id,'garment',garment,'operation',gen_random_uuid()));
    UPDATE api_private.image_uploads SET expires_at = now() - interval '1 second' WHERE id = (second->>'id')::uuid;
    PERFORM pg_temp.image_denied(jsonb_build_object('action','upload','owner',owner_id,'id',second->>'id'));
    PERFORM pg_temp.check_image(jsonb_array_length(app.images_command('{"action":"sweep"}')) = 1);
    DELETE FROM auth.users WHERE id = owner_id::uuid;
    PERFORM pg_temp.check_image((SELECT count(*) = 2 FROM api_private.image_uploads WHERE user_id = owner_id::uuid));
    PERFORM pg_temp.image_denied(jsonb_build_object('action','read','owner',owner_id,'id',image_id));
    PERFORM pg_temp.check_image(jsonb_array_length(app.images_command('{"action":"sweep"}')) = 2);
    PERFORM app.images_command(jsonb_build_object('action','swept','id',image_id));
    PERFORM pg_temp.check_image(jsonb_array_length(app.images_command('{"action":"sweep"}')) = 2);
END $$;
SET LOCAL ROLE authenticated;
DO $$ BEGIN
    BEGIN PERFORM app.images_command('{"action":"sweep"}'); RAISE EXCEPTION 'Client accessed worker';
    EXCEPTION WHEN insufficient_privilege THEN NULL; END;
    BEGIN PERFORM 1 FROM api_private.image_uploads; RAISE EXCEPTION 'Client accessed inventory';
    EXCEPTION WHEN insufficient_privilege THEN NULL; END;
END $$;
RESET ROLE;
SET LOCAL ROLE anon;
DO $$ BEGIN
    BEGIN PERFORM app.images_command('{"action":"sweep"}'); RAISE EXCEPTION 'Anonymous accessed worker';
    EXCEPTION WHEN insufficient_privilege THEN NULL; END;
END $$;
ROLLBACK;
