BEGIN;
CREATE FUNCTION pg_temp.check_export(ok boolean) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF ok IS DISTINCT FROM true THEN RAISE EXCEPTION 'Export assertion failed'; END IF; END $$;
INSERT INTO auth.users VALUES ('00000000-0000-0000-0000-000000000081'),('00000000-0000-0000-0000-000000000082');
INSERT INTO app.profiles(id,user_id) SELECT id,id FROM auth.users WHERE id::text LIKE '%00000000008_';
DO $$
DECLARE a uuid := '00000000-0000-0000-0000-000000000081';
    b uuid := '00000000-0000-0000-0000-000000000082';
    g uuid := gen_random_uuid(); outfit uuid := gen_random_uuid(); wear uuid := gen_random_uuid();
    op uuid := gen_random_uuid(); image uuid := gen_random_uuid(); req jsonb; first jsonb; snap jsonb;
BEGIN
    INSERT INTO app.garments(id,user_id,name,category,price_grosz,archived_at)
    VALUES(g,a,'Archived export garment','top',9223372036854775807,now());
    INSERT INTO app.garments(user_id,name,category) VALUES(b,'Other owner secret','top');
    INSERT INTO app.outfits(id,user_id,name) VALUES(outfit,a,'Export outfit');
    INSERT INTO app.wear_events(id,user_id,worn_on,timezone,client_request_id)
    VALUES(wear,a,'2020-01-02','Europe/Warsaw',gen_random_uuid());
    INSERT INTO app.wear_event_items(user_id,wear_event_id,garment_id) VALUES(a,wear,g);
    INSERT INTO app.planned_outfits(user_id,outfit_id,planned_on) VALUES(a,outfit,'2030-01-01');
    INSERT INTO app.garment_images(id,user_id,garment_id,variant,object_key,status,content_type)
    VALUES(image,a,g,'original','private-key','ready','image/jpeg');
    req := jsonb_build_object('owner',a,'id',op);
    first := app.exports_command(req || '{"action":"prepare"}');
    PERFORM pg_temp.check_export(first->>'id' = op::text);
    PERFORM pg_temp.check_export(app.exports_command(req || '{"action":"prepare"}') = first);
    PERFORM pg_temp.check_export(app.exports_command(req || jsonb_build_object('action','read','owner',b)) = 'null');
    PERFORM pg_temp.check_export(app.exports_command(req || jsonb_build_object('action','prepare','owner',b)) = 'null');
    snap := app.exports_command(req || '{"action":"read"}')->'snapshot';
    PERFORM pg_temp.check_export(jsonb_array_length(snap->'garments') = 1);
    PERFORM pg_temp.check_export(snap->'garments'->0->>'price_grosz' = '9223372036854775807');
    PERFORM pg_temp.check_export(snap->'wear_events'->0->>'worn_on' = '2020-01-02');
    PERFORM pg_temp.check_export(snap->'wear_event_items'->0->>'garment_id' = g::text);
    PERFORM pg_temp.check_export(snap->'planned_outfits'->0->>'planned_on' = '2030-01-01');
    PERFORM pg_temp.check_export(NOT snap ?| ARRAY['operator_audit','auth','sync_operations','ai_jobs']);
    UPDATE app.garments SET price_grosz = 0 WHERE id = g;
    PERFORM pg_temp.check_export(app.exports_command(req || '{"action":"read"}')->'snapshot' = snap);
    PERFORM pg_temp.check_export(app.exports_command(req || jsonb_build_object('action','image','image',image,'key','private-key')) = 'true');
    PERFORM pg_temp.check_export(app.exports_command(req || jsonb_build_object('action','image','image',image,'key','wrong-key')) = 'false');
    UPDATE app.garments SET deleted_at = now() WHERE id = g;
    PERFORM pg_temp.check_export(app.exports_command(req || jsonb_build_object('action','image','image',image,'key','private-key')) = 'false');
    UPDATE api_private.data_exports SET expires_at = clock_timestamp() - interval '1 second' WHERE id = op;
    PERFORM pg_temp.check_export(app.exports_command(req || '{"action":"read"}') = 'null');
    PERFORM pg_temp.check_export(app.exports_command(req || '{"action":"prepare"}') = 'null');
    PERFORM app.exports_command('{"action":"sweep"}');
    PERFORM pg_temp.check_export((SELECT snapshot IS NULL FROM api_private.data_exports WHERE id = op));
    req := jsonb_build_object('owner',a,'id',gen_random_uuid());
    PERFORM app.exports_command(req || '{"action":"prepare"}');
    UPDATE app.profiles SET deleted_at = now() WHERE user_id = a;
    PERFORM pg_temp.check_export(app.exports_command(req || '{"action":"read"}') = 'null');
    PERFORM app.exports_command('{"action":"sweep"}');
    PERFORM pg_temp.check_export(NOT EXISTS (SELECT FROM api_private.data_exports WHERE user_id = a AND snapshot IS NOT NULL));
    DELETE FROM auth.users WHERE id = a;
    PERFORM pg_temp.check_export(NOT EXISTS (SELECT FROM api_private.data_exports WHERE user_id = a));
    PERFORM pg_temp.check_export(EXISTS (SELECT FROM app.garments WHERE user_id = b));
END $$;
SELECT pg_temp.check_export(NOT has_function_privilege('authenticated','app.exports_command(jsonb)','EXECUTE'));
SELECT pg_temp.check_export(NOT has_function_privilege('anon','app.exports_command(jsonb)','EXECUTE'));
SELECT pg_temp.check_export(NOT has_table_privilege('authenticated','api_private.data_exports','SELECT'));
ROLLBACK;
