BEGIN;
CREATE FUNCTION pg_temp.check_image(ok boolean) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF ok IS DISTINCT FROM true THEN RAISE EXCEPTION 'Image assertion failed'; END IF; END $$;
INSERT INTO auth.users VALUES ('00000000-0000-0000-0000-000000000091'),('00000000-0000-0000-0000-000000000092');
INSERT INTO app.profiles(id,user_id) SELECT id,id FROM auth.users WHERE id::text LIKE '%00000000009_';
DO $$
DECLARE a uuid := '00000000-0000-0000-0000-000000000091';
    b uuid := '00000000-0000-0000-0000-000000000092';
    g uuid := gen_random_uuid(); op uuid := gen_random_uuid(); req jsonb; claim jsonb;
BEGIN
    INSERT INTO app.garments(id,user_id,name,category) VALUES(g,a,'Image test','top');
    req := jsonb_build_object('owner',a,'garment',g,'id',op);
    PERFORM pg_temp.check_image(app.images_command(req || '{"action":"prepare"}') ->> 'id' = op::text);
    PERFORM pg_temp.check_image(app.images_command(req || jsonb_build_object('action','prepare','owner',b)) = 'null');
    PERFORM pg_temp.check_image(app.images_command(req || '{"action":"read"}') = 'false');
    claim := app.images_command(req || '{"action":"claim"}');
    PERFORM pg_temp.check_image(claim->>'state' = 'processing');
    PERFORM pg_temp.check_image(app.images_command(req || '{"action":"claim"}') = 'null');
    PERFORM pg_temp.check_image(app.images_command(req || jsonb_build_object('action','finish','fence',gen_random_uuid())) = 'null');
    PERFORM pg_temp.check_image(app.images_command(req || jsonb_build_object('action','finish','fence',claim->>'fence')) = 'true');
    PERFORM pg_temp.check_image(app.images_command(req || '{"action":"read"}') = 'true');
    PERFORM pg_temp.check_image(app.images_command(req || jsonb_build_object('action','read','owner',b)) = 'null');
    PERFORM pg_temp.check_image(app.images_command(req || '{"action":"claim"}')->>'state' = 'ready');
    PERFORM pg_temp.check_image((SELECT count(*) = 2 FROM app.garment_images WHERE garment_id = g));
    DELETE FROM auth.users WHERE id = a;
    PERFORM pg_temp.check_image(app.images_command(req || '{"action":"read"}') = 'null');
    PERFORM pg_temp.check_image(jsonb_array_length(app.images_command('{"action":"sweep"}')) = 1);
    PERFORM pg_temp.check_image((SELECT state = 'retired' FROM api_private.image_uploads WHERE id = op));
    PERFORM app.images_command(req || '{"action":"cleaned"}');
    PERFORM pg_temp.check_image(jsonb_array_length(app.images_command('{"action":"sweep"}')) = 0);
    -- An interrupted process cannot publish after lease expiry, even before sweep.
    g := gen_random_uuid(); op := gen_random_uuid();
    INSERT INTO app.garments(id,user_id,name,category) VALUES(g,b,'Expired upload','top');
    req := jsonb_build_object('owner',b,'garment',g,'id',op);
    PERFORM app.images_command(req || '{"action":"prepare"}');
    claim := app.images_command(req || '{"action":"claim"}');
    UPDATE api_private.image_uploads SET expires_at = clock_timestamp() - interval '1 second' WHERE id = op;
    PERFORM pg_temp.check_image(app.images_command(req || jsonb_build_object('action','finish','fence',claim->>'fence')) = 'null');
    PERFORM pg_temp.check_image(jsonb_array_length(app.images_command('{"action":"sweep"}')) = 1);
    PERFORM pg_temp.check_image(app.images_command(req || '{"action":"claim"}') = 'null');
    -- Without a cleanup acknowledgement the durable deletion is returned again.
    PERFORM pg_temp.check_image(jsonb_array_length(app.images_command('{"action":"sweep"}')) = 1);
END $$;
DO $$
DECLARE owner uuid := gen_random_uuid(); garment uuid := gen_random_uuid(); operation uuid := gen_random_uuid(); request jsonb; claim jsonb;
BEGIN
    INSERT INTO auth.users VALUES(owner);
    INSERT INTO app.profiles(id,user_id) VALUES(owner,owner);
    INSERT INTO app.garments(id,user_id,name,category) VALUES(garment,owner,'Source and edit','top');
    request := jsonb_build_object('owner',owner,'garment',garment,'id',operation,'has_cleaned',true);
    PERFORM pg_temp.check_image(app.images_command(request || '{"action":"prepare"}')->>'id'=operation::text);
    PERFORM pg_temp.check_image(app.images_command(request || '{"action":"prepare","has_cleaned":false}')='null');
    claim := app.images_command(request || '{"action":"claim"}');
    PERFORM pg_temp.check_image((claim->>'has_cleaned')::boolean);
    PERFORM pg_temp.check_image(app.images_command(request || jsonb_build_object('action','finish','fence',claim->>'fence'))='true');
    PERFORM pg_temp.check_image((SELECT count(*)=3 FROM app.garment_images WHERE garment_id=garment));
    PERFORM pg_temp.check_image(app.images_command(request || '{"action":"read","variant":"cleaned"}')='true');
    PERFORM pg_temp.check_image(app.images_command(request || '{"action":"read","variant":"unknown"}')='false');
    PERFORM pg_temp.check_image((SELECT (api_private.wardrobe_item(g)->>'hasCleanedImage')::boolean FROM app.garments g WHERE id=garment));
    PERFORM pg_temp.check_image((SELECT content_type='image/png' AND object_key=operation::text||'/cleaned.png' FROM app.garment_images WHERE garment_id=garment AND variant='cleaned'));
    -- A missing paired variant invalidates the entire publication, including source.
    DELETE FROM app.garment_images WHERE garment_id=garment AND variant='cleaned';
    PERFORM pg_temp.check_image(app.images_command(request || '{"action":"read"}')='false');
    PERFORM app.images_command('{"action":"sweep"}');
    PERFORM pg_temp.check_image((SELECT state='retired' FROM api_private.image_uploads WHERE id=operation));
    PERFORM app.images_command(request || '{"action":"cleaned"}');
    PERFORM pg_temp.check_image(NOT EXISTS(SELECT FROM app.garment_images WHERE garment_id=garment));
END $$;
DO $$
DECLARE owner uuid:=gen_random_uuid(); garment uuid:=gen_random_uuid(); old_id uuid:=gen_random_uuid(); new_id uuid:=gen_random_uuid();
    request jsonb; old_claim jsonb; new_claim jsonb;
BEGIN
    INSERT INTO auth.users VALUES(owner);
    INSERT INTO app.profiles(id,user_id) VALUES(owner,owner);
    INSERT INTO app.garments(id,user_id,name,category) VALUES(garment,owner,'Interrupted upload','top');
    request:=jsonb_build_object('owner',owner,'garment',garment,'id',old_id,'has_cleaned',true);
    PERFORM app.images_command(request||'{"action":"prepare"}');
    old_claim:=app.images_command(request||'{"action":"claim"}');
    UPDATE api_private.image_uploads SET expires_at=clock_timestamp()-interval '1 second' WHERE id=old_id;
    PERFORM pg_temp.check_image((app.images_command(request||'{"action":"prepare"}')->>'expired')::boolean);
    PERFORM pg_temp.check_image(app.images_command(request||jsonb_build_object('action','finish','fence',old_claim->>'fence'))='null');
    PERFORM pg_temp.check_image(app.images_command(request||jsonb_build_object('action','prepare','owner',gen_random_uuid()))='null');
    PERFORM app.images_command(request||jsonb_build_object('action','prepare','id',new_id));
    new_claim:=app.images_command(request||jsonb_build_object('action','claim','id',new_id));
    PERFORM pg_temp.check_image(app.images_command(request||jsonb_build_object('action','finish','id',new_id,'fence',new_claim->>'fence'))='true');
    -- Repeated old prepare/cleanup and a delayed old finish cannot affect the new namespace.
    PERFORM pg_temp.check_image((app.images_command(request||'{"action":"prepare"}')->>'expired')::boolean);
    PERFORM app.images_command('{"action":"sweep"}');
    PERFORM app.images_command(request||'{"action":"cleaned"}');
    PERFORM pg_temp.check_image(app.images_command(request||jsonb_build_object('action','read','id',new_id,'variant','cleaned'))='true');
    PERFORM pg_temp.check_image((SELECT count(*)=3 FROM app.garment_images WHERE garment_id=garment));
    PERFORM pg_temp.check_image(NOT EXISTS(SELECT FROM app.garment_images WHERE garment_id=garment AND object_key LIKE old_id::text||'/%'));
    DELETE FROM auth.users WHERE id=owner;
    PERFORM pg_temp.check_image(app.images_command(request||'{"action":"prepare"}')='null');
END $$;
SELECT pg_temp.check_image(NOT has_function_privilege('authenticated','app.images_command(jsonb)','EXECUTE'));
SELECT pg_temp.check_image(NOT has_table_privilege('authenticated','api_private.image_uploads','SELECT'));
ROLLBACK;
