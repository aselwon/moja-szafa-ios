BEGIN;
CREATE FUNCTION pg_temp.assert_true(ok boolean, message text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    IF ok IS DISTINCT FROM true THEN RAISE EXCEPTION 'Assertion failed: %', message; END IF;
END $$;
CREATE FUNCTION pg_temp.expect_error(statement text, expected_state text) RETURNS void LANGUAGE plpgsql AS $$
DECLARE actual_state text;
BEGIN
    BEGIN
        EXECUTE statement;
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS actual_state = RETURNED_SQLSTATE;
    END;
    IF actual_state IS DISTINCT FROM expected_state THEN
        RAISE EXCEPTION 'Expected SQLSTATE %, got % for %', expected_state, actual_state, statement;
    END IF;
END $$;
CREATE FUNCTION pg_temp.uid(n integer) RETURNS uuid LANGUAGE sql IMMUTABLE AS $$
    SELECT lpad(n::text, 32, '0')::uuid
$$;
SELECT pg_temp.assert_true((SELECT count(*) = 22 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'app' AND c.relkind = 'r' AND c.relrowsecurity AND c.relforcerowsecurity), '22 tables must enforce RLS');
SELECT pg_temp.assert_true((SELECT count(*) = 12 FROM migration_meta.versions), 'all twelve available migrations recorded');
INSERT INTO auth.users VALUES (pg_temp.uid(101)), (pg_temp.uid(102));
INSERT INTO app.profiles (id, user_id) VALUES (pg_temp.uid(101),pg_temp.uid(101)), (pg_temp.uid(102),pg_temp.uid(102));
INSERT INTO app.garments (id, user_id, name, category, price_grosz) VALUES
    (pg_temp.uid(201), pg_temp.uid(101), 'A shirt', 'top', 80000),
    (pg_temp.uid(202), pg_temp.uid(102), 'B shirt', 'top', NULL);
INSERT INTO app.outfits (id, user_id, name) VALUES (pg_temp.uid(301),pg_temp.uid(101),'A outfit'),(pg_temp.uid(302),pg_temp.uid(102),'B outfit');
INSERT INTO app.outfit_items (user_id, outfit_id, garment_id, position) VALUES (pg_temp.uid(101),pg_temp.uid(301),pg_temp.uid(201),0);
INSERT INTO app.wear_events (id,user_id,worn_on,timezone,client_request_id,source_outfit_id) VALUES
    (pg_temp.uid(401),pg_temp.uid(101),DATE '2026-01-01','Europe/Warsaw',pg_temp.uid(401),pg_temp.uid(301)),
    (pg_temp.uid(402),pg_temp.uid(101),DATE '2026-01-01','Europe/Warsaw',pg_temp.uid(402),NULL),
    (pg_temp.uid(403),pg_temp.uid(102),DATE '2026-01-01','Europe/Warsaw',pg_temp.uid(403),NULL);
INSERT INTO app.wear_event_items (user_id,wear_event_id,garment_id) VALUES
    (pg_temp.uid(101),pg_temp.uid(401),pg_temp.uid(201)),(pg_temp.uid(101),pg_temp.uid(402),pg_temp.uid(201));
INSERT INTO app.trips (id,user_id,destination,starts_on,ends_on) VALUES
    (pg_temp.uid(501),pg_temp.uid(101),'A city','2026-01-01','2026-01-02'),(pg_temp.uid(502),pg_temp.uid(102),'B city','2026-01-01','2026-01-02');
INSERT INTO app.ai_jobs (id,user_id,client_request_id,kind) VALUES (pg_temp.uid(601),pg_temp.uid(101),pg_temp.uid(601),'image_analysis'),(pg_temp.uid(602),pg_temp.uid(102),pg_temp.uid(602),'image_analysis');
INSERT INTO app.subscription_entitlements (id,user_id,original_transaction_id,product_id,status,verified_at,environment) VALUES
    (pg_temp.uid(701),pg_temp.uid(101),'test-a','test-plus','active',now(),'sandbox'),
    (pg_temp.uid(702),pg_temp.uid(102),'test-b','test-plus','active',now(),'sandbox');
INSERT INTO app.garment_images (user_id,garment_id,variant,object_key) VALUES (pg_temp.uid(101),pg_temp.uid(201),'original','synthetic/a');
INSERT INTO app.preferences (user_id) VALUES (pg_temp.uid(101));
INSERT INTO app.outfit_feedback (user_id,outfit_id,rating) VALUES (pg_temp.uid(101),pg_temp.uid(301),'like');
INSERT INTO app.consent_events (user_id,purpose,policy_version,recipient,granted,client_request_id) VALUES (pg_temp.uid(101),'ai','v1','test-recipient',false,pg_temp.uid(801));
INSERT INTO app.planned_outfits (user_id,outfit_id,planned_on) VALUES (pg_temp.uid(101),pg_temp.uid(301),CURRENT_DATE + 10);
INSERT INTO app.trip_items (user_id,trip_id,garment_id) VALUES (pg_temp.uid(101),pg_temp.uid(501),pg_temp.uid(201));
INSERT INTO app.purchase_candidates (user_id,expires_at) VALUES (pg_temp.uid(101),now()+interval '1 day');
INSERT INTO app.subscription_events (user_id,notification_id,entitlement_id,event_type,occurred_at) VALUES (pg_temp.uid(101),pg_temp.uid(901),pg_temp.uid(701),'test',now());
INSERT INTO app.usage_reservations (user_id,ai_job_id,client_request_id,units,expires_at) VALUES (pg_temp.uid(101),pg_temp.uid(601),pg_temp.uid(1001),1,now()+interval '1 hour');
INSERT INTO app.sync_operations (user_id,client_request_id,entity_type,entity_id,status) VALUES (pg_temp.uid(101),pg_temp.uid(1101),'garments',pg_temp.uid(201),'pending');
INSERT INTO app.deletion_jobs (user_id,client_request_id) VALUES (pg_temp.uid(101),pg_temp.uid(1201));
INSERT INTO app.support_requests (user_id,client_request_id,subject,message) VALUES (pg_temp.uid(101),pg_temp.uid(1301),'Test','Synthetic');
INSERT INTO app.operator_audit (user_id,operator_id,action,target_type,request_id,outcome) VALUES (pg_temp.uid(101),pg_temp.uid(1401),'test','profile',pg_temp.uid(1402),'allowed');

-- Exercise the actual non-owner role: a superuser SELECT cannot test RLS.
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',pg_temp.uid(101)::text,true);
DO $$ DECLARE t text; total integer; foreign_count integer; BEGIN
    FOR t IN SELECT tablename FROM pg_tables WHERE schemaname = 'app' AND tablename <> 'operator_audit' LOOP
        EXECUTE format('SELECT count(*), count(*) FILTER (WHERE user_id <> auth.uid()) FROM app.%I', t) INTO total, foreign_count;
        PERFORM pg_temp.assert_true(total > 0 AND foreign_count = 0, 'owner-only reads: ' || t);
        PERFORM pg_temp.expect_error(format('DELETE FROM app.%I',t),'42501');
        PERFORM pg_temp.expect_error(format('UPDATE app.%I SET version = version + 1',t),'42501');
        PERFORM pg_temp.expect_error(format('INSERT INTO app.%I DEFAULT VALUES',t),'42501');
    END LOOP;
END $$;
SELECT pg_temp.expect_error('SELECT * FROM app.operator_audit','42501');
SELECT set_config('request.jwt.claim.sub',pg_temp.uid(102)::text,true);
SELECT pg_temp.assert_true((SELECT count(*) = 1 FROM app.garments), 'B sees only B garment');
SELECT set_config('request.jwt.claim.sub','',true);
DO $$ DECLARE t text; total integer; BEGIN
    FOR t IN SELECT tablename FROM pg_tables WHERE schemaname = 'app' AND tablename <> 'operator_audit' LOOP
        EXECUTE format('SELECT count(*) FROM app.%I',t) INTO total;
        PERFORM pg_temp.assert_true(total = 0,'missing identity denies reads: ' || t);
    END LOOP;
END $$;
RESET ROLE;
SET LOCAL ROLE anon;
SELECT pg_temp.expect_error('SELECT * FROM app.garments','42501');
RESET ROLE;

-- Composite foreign keys still enforce ownership for the trusted backend,
-- even though that role bypasses row-level policies.
SET LOCAL ROLE service_role;
SELECT pg_temp.expect_error($q$INSERT INTO app.outfit_items(user_id,outfit_id,garment_id,position) VALUES(pg_temp.uid(101),pg_temp.uid(301),pg_temp.uid(202),1)$q$,'23503');
SELECT pg_temp.expect_error($q$INSERT INTO app.wear_event_items(user_id,wear_event_id,garment_id) VALUES(pg_temp.uid(101),pg_temp.uid(403),pg_temp.uid(201))$q$,'23503');
SELECT pg_temp.expect_error($q$INSERT INTO app.wear_event_items(user_id,wear_event_id,garment_id) VALUES(pg_temp.uid(101),pg_temp.uid(401),pg_temp.uid(202))$q$,'23503');
SELECT pg_temp.expect_error($q$INSERT INTO app.garment_images(user_id,garment_id,variant,object_key) VALUES(pg_temp.uid(101),pg_temp.uid(202),'thumbnail','synthetic/invalid')$q$,'23503');
SELECT pg_temp.expect_error($q$UPDATE app.wear_events SET source_outfit_id = pg_temp.uid(302) WHERE id = pg_temp.uid(401)$q$,'23503');
SELECT pg_temp.expect_error($q$UPDATE app.planned_outfits SET outfit_id = pg_temp.uid(302) WHERE user_id = pg_temp.uid(101)$q$,'23503');
SELECT pg_temp.expect_error($q$UPDATE app.outfit_feedback SET outfit_id = pg_temp.uid(302) WHERE user_id = pg_temp.uid(101)$q$,'23503');
SELECT pg_temp.expect_error($q$UPDATE app.trip_items SET trip_id = pg_temp.uid(502) WHERE user_id = pg_temp.uid(101)$q$,'23503');
SELECT pg_temp.expect_error($q$UPDATE app.trip_items SET garment_id = pg_temp.uid(202) WHERE user_id = pg_temp.uid(101)$q$,'23503');
SELECT pg_temp.expect_error($q$UPDATE app.purchase_candidates SET status = 'purchased', purchased_garment_id = pg_temp.uid(202) WHERE user_id = pg_temp.uid(101)$q$,'23503');
SELECT pg_temp.expect_error($q$INSERT INTO app.subscription_events(user_id,notification_id,entitlement_id,event_type,occurred_at) VALUES(pg_temp.uid(101),pg_temp.uid(902),pg_temp.uid(702),'test',now())$q$,'23503');
SELECT pg_temp.expect_error($q$UPDATE app.usage_reservations SET ai_job_id = pg_temp.uid(602) WHERE user_id = pg_temp.uid(101)$q$,'23503');
SELECT pg_temp.expect_error($q$INSERT INTO app.wear_events(user_id,worn_on,timezone,client_request_id) VALUES(pg_temp.uid(101),'2026-01-01','UTC',pg_temp.uid(401))$q$,'23505');
SELECT pg_temp.expect_error($q$INSERT INTO app.ai_jobs(user_id,kind,client_request_id) VALUES(pg_temp.uid(101),'image_analysis',pg_temp.uid(601))$q$,'23505');
SELECT pg_temp.expect_error($q$INSERT INTO app.wear_events(user_id,worn_on,timezone,client_request_id) VALUES(pg_temp.uid(101),CURRENT_DATE + 2,'UTC',gen_random_uuid())$q$,'23514');
SELECT pg_temp.expect_error($q$UPDATE app.wear_events SET timezone = 'invalid/timezone' WHERE id = pg_temp.uid(401)$q$,'23514');
SELECT pg_temp.expect_error($q$UPDATE app.garments SET price_grosz = -1 WHERE id = pg_temp.uid(201)$q$,'23514');
SELECT pg_temp.expect_error($q$UPDATE app.garments SET currency = 'EUR' WHERE id = pg_temp.uid(201)$q$,'23514');
SELECT pg_temp.expect_error($q$UPDATE app.garments SET estimated_prior_wears = 10 WHERE id = pg_temp.uid(201)$q$,'23514');
SELECT pg_temp.expect_error($q$UPDATE app.garments SET availability = 'archived' WHERE id = pg_temp.uid(201)$q$,'23514');
SELECT pg_temp.expect_error($q$UPDATE app.garments SET user_id = pg_temp.uid(102) WHERE id = pg_temp.uid(201)$q$,'23514');
SELECT pg_temp.expect_error($q$UPDATE app.ai_jobs SET status = 'running' WHERE id = pg_temp.uid(601)$q$,'23514');
SELECT pg_temp.expect_error($q$UPDATE app.consent_events SET granted = true$q$,'23514');
SELECT pg_temp.expect_error($q$UPDATE app.subscription_events SET event_type = 'altered'$q$,'23514');
SELECT pg_temp.expect_error($q$UPDATE app.operator_audit SET action = 'altered'$q$,'23514');

UPDATE app.garments SET price_grosz = 0 WHERE id = pg_temp.uid(201);
SELECT pg_temp.assert_true((SELECT version = 2 AND price_grosz = 0 FROM app.garments WHERE id = pg_temp.uid(201)), 'price change increments version');
DELETE FROM app.outfit_items WHERE outfit_id = pg_temp.uid(301);
SELECT pg_temp.assert_true((SELECT count(*) = 2 FROM app.wear_event_items WHERE garment_id = pg_temp.uid(201)), 'outfit editing preserves historical items');
SELECT pg_temp.assert_true((SELECT count(DISTINCT e.worn_on) = 1 FROM app.wear_events e JOIN app.wear_event_items i ON (i.user_id,i.wear_event_id) = (e.user_id,e.id) WHERE i.garment_id = pg_temp.uid(201) AND e.deleted_at IS NULL AND i.deleted_at IS NULL), 'two live events on one day count once');
UPDATE app.wear_events SET deleted_at = now() WHERE id = pg_temp.uid(401);
DELETE FROM app.outfits WHERE id = pg_temp.uid(301);
SELECT pg_temp.assert_true((SELECT source_outfit_id IS NULL AND user_id = pg_temp.uid(101) FROM app.wear_events WHERE id = pg_temp.uid(401)), 'deleting outfit clears only optional source, preserving owner and history');
SET LOCAL TIME ZONE 'Pacific/Honolulu';
SELECT pg_temp.assert_true((SELECT worn_on = DATE '2026-01-01' FROM app.wear_events WHERE id = pg_temp.uid(401)), 'timezone changes preserve calendar day');
SELECT pg_temp.assert_true((SELECT count(DISTINCT e.worn_on) = 1 FROM app.wear_events e JOIN app.wear_event_items i ON (i.user_id,i.wear_event_id) = (e.user_id,e.id) WHERE i.garment_id = pg_temp.uid(201) AND e.deleted_at IS NULL AND i.deleted_at IS NULL), 'live events on one day count once');
DELETE FROM app.wear_events WHERE id = pg_temp.uid(401);
SELECT pg_temp.assert_true((SELECT count(*) = 1 FROM app.wear_event_items WHERE garment_id = pg_temp.uid(201)), 'undo preserves second event');
UPDATE app.garments SET archived_at = now(), availability = 'laundry' WHERE id = pg_temp.uid(201);
SELECT pg_temp.assert_true((SELECT count(*) = 1 FROM app.wear_event_items WHERE garment_id = pg_temp.uid(201)), 'archiving preserves history');
UPDATE app.garments SET deleted_at = now() WHERE id = pg_temp.uid(201);
SELECT pg_temp.expect_error($q$UPDATE app.garments SET name = 'stale edit', deleted_at = NULL WHERE id = pg_temp.uid(201)$q$,'23514');
DELETE FROM app.garments WHERE id = pg_temp.uid(201);
SELECT pg_temp.assert_true((SELECT count(*) = 0 FROM app.garment_images WHERE user_id = pg_temp.uid(101)), 'hard deletion removes image metadata');
SELECT pg_temp.assert_true((SELECT count(*) = 0 FROM app.wear_event_items WHERE user_id = pg_temp.uid(101)), 'hard deletion removes wear relationships');
RESET ROLE;
DELETE FROM auth.users WHERE id = pg_temp.uid(101);
SELECT pg_temp.assert_true((SELECT count(*) = 0 FROM app.profiles WHERE user_id = pg_temp.uid(101)), 'auth deletion cascades profile');
SELECT pg_temp.assert_true((SELECT count(*) = 1 FROM app.deletion_jobs WHERE user_id = pg_temp.uid(101)), 'cleanup job survives account deletion');
SELECT pg_temp.assert_true((SELECT count(*) = 1 FROM app.operator_audit WHERE user_id = pg_temp.uid(101)), 'audit survives account deletion');
SELECT pg_temp.assert_true((SELECT count(*) = 1 FROM app.garments WHERE user_id = pg_temp.uid(102)), 'account deletion preserves other owner');
ROLLBACK;
