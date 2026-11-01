\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.assert_true(ok boolean, description text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF ok IS DISTINCT FROM true THEN RAISE EXCEPTION 'Assertion: %', description; END IF; END $$;
CREATE FUNCTION pg_temp.expect_error(statement text, expected text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    BEGIN EXECUTE statement;
    EXCEPTION WHEN OTHERS THEN
        IF SQLSTATE = expected THEN RETURN; END IF;
        RAISE EXCEPTION 'Expected %, received %: %', expected, SQLSTATE, SQLERRM;
    END;
    RAISE EXCEPTION 'Expected % but statement succeeded: %', expected, statement;
END $$;

INSERT INTO auth.users VALUES ('00000000-0000-0000-0000-000000000001'), ('00000000-0000-0000-0000-000000000002');
INSERT INTO app.profiles (id) SELECT id FROM auth.users;
INSERT INTO app.garments (id,user_id,name,category,price_grosz) VALUES
('10000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000001','A','top',80000),
('10000000-0000-0000-0000-000000000002','00000000-0000-0000-0000-000000000002','B','shoes',NULL);
INSERT INTO app.outfits (id,user_id,name) VALUES
('40000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000001','A');
INSERT INTO app.outfit_items (user_id,outfit_id,garment_id,position) VALUES
('00000000-0000-0000-0000-000000000001','40000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000001',0);
INSERT INTO app.wear_events (id,user_id,worn_on,timezone,client_request_id,source_outfit_id) VALUES
('20000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000001','2020-01-01','Europe/Warsaw','30000000-0000-0000-0000-000000000001','40000000-0000-0000-0000-000000000001'),
('20000000-0000-0000-0000-000000000002','00000000-0000-0000-0000-000000000001','2020-01-01','Europe/Warsaw','30000000-0000-0000-0000-000000000002',NULL);
INSERT INTO app.wear_event_items (user_id,wear_event_id,garment_id)
SELECT user_id,id,'10000000-0000-0000-0000-000000000001' FROM app.wear_events;

SELECT pg_temp.expect_error($q$UPDATE app.garments SET price_grosz=-1$q$,'23514');
SELECT pg_temp.expect_error($q$UPDATE app.garments SET currency='EUR'$q$,'23514');
SELECT pg_temp.expect_error($q$UPDATE app.garments SET availability='missing'$q$,'23514');
SELECT pg_temp.expect_error($q$UPDATE app.garments SET estimated_prior_wears=10$q$,'23514');
SELECT pg_temp.expect_error($q$UPDATE app.garments SET user_id='00000000-0000-0000-0000-000000000002' WHERE name='A'$q$,'23514');
SELECT pg_temp.expect_error($q$UPDATE app.wear_events SET worn_on=CURRENT_DATE+2$q$,'23514');
SELECT pg_temp.expect_error($q$UPDATE app.wear_events SET timezone='Invalid/Zone'$q$,'23514');
SELECT pg_temp.expect_error($q$UPDATE app.wear_events SET client_request_id='30000000-0000-0000-0000-000000000001' WHERE id='20000000-0000-0000-0000-000000000002'$q$,'23505');
-- Cross-owner references must fail even with BYPASSRLS (server mistakes).
SELECT pg_temp.expect_error($q$UPDATE app.outfit_items SET garment_id='10000000-0000-0000-0000-000000000002'$q$,'23503');
SELECT pg_temp.expect_error($q$UPDATE app.wear_event_items SET garment_id='10000000-0000-0000-0000-000000000002'$q$,'23503');
SELECT pg_temp.expect_error($q$INSERT INTO app.garment_images (user_id,garment_id,kind,object_key) VALUES ('00000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000002','original','synthetic')$q$,'23503');

UPDATE app.garments SET price_grosz=0, availability='laundry', archived_at=now() WHERE name='A';
SELECT pg_temp.assert_true((SELECT version=2 AND price_grosz=0 FROM app.garments WHERE name='A'),'version advances and zero price supported');
DELETE FROM app.outfits;
SELECT pg_temp.assert_true((SELECT count(*)=2 FROM app.wear_event_items),'outfit edits/deletion preserve wear snapshot');
SELECT pg_temp.assert_true((SELECT bool_and(source_outfit_id IS NULL) FROM app.wear_events),'source removed without removing owner');
SELECT pg_temp.assert_true((SELECT count(DISTINCT worn_on)=1 FROM app.wear_events),'same day remains one wear day');
DELETE FROM app.wear_events WHERE id='20000000-0000-0000-0000-000000000001';
SELECT pg_temp.assert_true((SELECT count(*)=1 FROM app.wear_event_items),'undo leaves other event intact');

-- Exercise the remaining ownership edges, including optional references.
INSERT INTO app.outfits (id,user_id,name) VALUES
('40000000-0000-0000-0000-000000000002','00000000-0000-0000-0000-000000000002','B');
INSERT INTO app.trips (id,user_id,name,destination,starts_on,ends_on) VALUES
('50000000-0000-0000-0000-000000000002','00000000-0000-0000-0000-000000000002','B','Test','2027-01-01','2027-01-02');
INSERT INTO app.ai_jobs (id,user_id,operation_id,kind) VALUES
('60000000-0000-0000-0000-000000000002','00000000-0000-0000-0000-000000000002',gen_random_uuid(),'outfits');
SELECT pg_temp.expect_error($q$UPDATE app.wear_events SET source_outfit_id='40000000-0000-0000-0000-000000000002'$q$,'23503');
SELECT pg_temp.expect_error($q$INSERT INTO app.outfit_feedback (user_id,outfit_id,rating) VALUES ('00000000-0000-0000-0000-000000000001','40000000-0000-0000-0000-000000000002','useful')$q$,'23503');
SELECT pg_temp.expect_error($q$INSERT INTO app.planned_outfits (user_id,outfit_id,planned_on,timezone) VALUES ('00000000-0000-0000-0000-000000000001','40000000-0000-0000-0000-000000000002',CURRENT_DATE,'UTC')$q$,'23503');
SELECT pg_temp.expect_error($q$INSERT INTO app.trip_items (user_id,trip_id,garment_id) VALUES ('00000000-0000-0000-0000-000000000001','50000000-0000-0000-0000-000000000002','10000000-0000-0000-0000-000000000002')$q$,'23503');
SELECT pg_temp.expect_error($q$INSERT INTO app.purchase_candidates (user_id,object_key,expires_at,purchased_garment_id) VALUES ('00000000-0000-0000-0000-000000000001','test',now()+interval '1 day','10000000-0000-0000-0000-000000000002')$q$,'23503');
SELECT pg_temp.expect_error($q$INSERT INTO app.usage_reservations (user_id,ai_job_id,operation_id,units,expires_at) VALUES ('00000000-0000-0000-0000-000000000001','60000000-0000-0000-0000-000000000002',gen_random_uuid(),1,now()+interval '1 hour')$q$,'23503');
SELECT pg_temp.expect_error($q$UPDATE app.ai_jobs SET status='running'$q$,'23514');
SELECT pg_temp.expect_error($q$UPDATE app.ai_jobs SET attempts=max_attempts+1$q$,'23514');
SELECT pg_temp.expect_error($q$UPDATE app.trips SET ends_on=starts_on-1$q$,'23514');
SELECT pg_temp.expect_error($q$INSERT INTO app.consent_events (user_id,purpose,policy_version,granted,operation_id) VALUES ('00000000-0000-0000-0000-000000000001','ai','1',true,gen_random_uuid())$q$,'23514');
INSERT INTO app.usage_reservations (user_id,ai_job_id,operation_id,units,expires_at)
SELECT user_id,id,gen_random_uuid(),1,now()+interval '1 hour' FROM app.ai_jobs;
SELECT pg_temp.expect_error($q$INSERT INTO app.usage_reservations (user_id,ai_job_id,operation_id,units,expires_at) SELECT user_id,id,gen_random_uuid(),1,now()+interval '1 hour' FROM app.ai_jobs$q$,'23505');

-- Assert security configuration for every application table, not just fixtures.
SELECT pg_temp.assert_true((SELECT count(*)=22 FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='app' AND c.relkind='r' AND c.relrowsecurity AND c.relforcerowsecurity),'all 22 domain tables enforce RLS');
DO $$ DECLARE t record; BEGIN
    FOR t IN SELECT tablename FROM pg_tables WHERE schemaname='app' LOOP
        PERFORM pg_temp.assert_true(NOT has_table_privilege('authenticated', 'app.'||t.tablename, 'INSERT,UPDATE,DELETE,TRUNCATE'), 'no direct client mutation: '||t.tablename);
        PERFORM pg_temp.assert_true(NOT has_table_privilege('anon', 'app.'||t.tablename, 'SELECT,INSERT,UPDATE,DELETE'), 'no anonymous access: '||t.tablename);
    END LOOP;
END $$;
SELECT set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000001',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.assert_true((SELECT count(*)=1 FROM app.profiles),'profile isolation');
SELECT pg_temp.assert_true((SELECT count(*)=1 FROM app.garments),'garment isolation');
SELECT pg_temp.assert_true((SELECT count(*)=0 FROM app.ai_jobs),'job isolation');
SELECT pg_temp.assert_true((SELECT count(*)=0 FROM app.usage_reservations),'reservation isolation');
SELECT pg_temp.assert_true((SELECT count(*)=0 FROM app.trips),'trip isolation');
SELECT pg_temp.assert_true((SELECT count(*)=1 FROM app.wear_event_items),'owned child visible');
SELECT pg_temp.expect_error('SELECT * FROM app.operator_audit','42501');
SELECT pg_temp.expect_error('SELECT * FROM app.subscription_events','42501');
SELECT pg_temp.expect_error('SELECT * FROM app.deletion_jobs','42501');
SELECT pg_temp.expect_error('UPDATE app.garments SET price_grosz=1','42501');
SELECT set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000002',true);
SELECT pg_temp.assert_true((SELECT count(*)=0 FROM app.wear_event_items),'other owner cannot read child');
SELECT set_config('request.jwt.claim.sub','',true);
SELECT pg_temp.assert_true((SELECT count(*)=0 FROM app.garments),'missing identity sees nothing');
RESET ROLE;
-- Exercise SET NULL and CASCADE together during a tombstoned account erase.
INSERT INTO app.outfits (id,user_id,name) VALUES
('40000000-0000-0000-0000-000000000003','00000000-0000-0000-0000-000000000001','Deletion source');
UPDATE app.wear_events SET source_outfit_id='40000000-0000-0000-0000-000000000003';
INSERT INTO app.purchase_candidates (user_id,object_key,expires_at,purchased_garment_id) VALUES
('00000000-0000-0000-0000-000000000001','deletion-candidate',now()+interval '1 day','10000000-0000-0000-0000-000000000001');
SET LOCAL ROLE service_role;
INSERT INTO app.consent_events (user_id,purpose,policy_version,recipient,granted,operation_id) VALUES
('00000000-0000-0000-0000-000000000001','ai','1','Test recipient',true,gen_random_uuid());
SELECT pg_temp.expect_error('UPDATE app.consent_events SET granted=false','42501');
SELECT pg_temp.expect_error('DELETE FROM app.operator_audit','42501');
INSERT INTO app.deletion_jobs (user_id,operation_id) VALUES ('00000000-0000-0000-0000-000000000001',gen_random_uuid());
SELECT pg_temp.expect_error($q$UPDATE app.garments SET name='stale' WHERE name='A'$q$,'23514');
RESET ROLE;
DELETE FROM auth.users WHERE id='00000000-0000-0000-0000-000000000001';
SELECT pg_temp.assert_true((SELECT count(*)=0 FROM app.wear_event_items),'account cascade clears historical relations');
SELECT pg_temp.assert_true((SELECT count(*)=0 FROM app.consent_events),'account cascade erases consent');
SELECT pg_temp.assert_true((SELECT count(*)=1 FROM app.deletion_jobs),'cleanup survives auth deletion');
SELECT pg_temp.assert_true((SELECT count(*)=1 FROM app.garments),'other account survives deletion');
ROLLBACK;
