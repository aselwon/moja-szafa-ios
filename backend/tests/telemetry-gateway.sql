-- Provider-shaped tables support the real bootstrap; these are isolated fixtures,
-- not evidence of a real Managed Auth login or session.
BEGIN;
CREATE SCHEMA neon_auth;
CREATE TABLE neon_auth."user" (id uuid PRIMARY KEY,"emailVerified" boolean,banned boolean);
CREATE TABLE neon_auth.session (id uuid PRIMARY KEY,"userId" uuid,"expiresAt" timestamptz,"impersonatedBy" text);
\ir ../deploy/neon-bootstrap.sql
INSERT INTO auth.users(id) VALUES('00000000-0000-0000-0000-000000000095');
INSERT INTO app.profiles(id,user_id) VALUES('00000000-0000-0000-0000-000000000095','00000000-0000-0000-0000-000000000095');
INSERT INTO api_private.telemetry_events(user_id,id,received_at,kind,data)
 VALUES('00000000-0000-0000-0000-000000000095',gen_random_uuid(),clock_timestamp()-interval '31 days','session','{}'),
 ('00000000-0000-0000-0000-000000000095',gen_random_uuid(),clock_timestamp(),'session','{}');
SET LOCAL ROLE szafa_gateway;
DO $$ BEGIN
 IF current_user <> 'szafa_gateway' THEN RAISE EXCEPTION 'Wrong maintenance test role'; END IF;
 IF app.telemetry_prune() <> 1 THEN RAISE EXCEPTION 'Gateway must prune exactly the expired row'; END IF;
 BEGIN
  PERFORM 1 FROM api_private.telemetry_events;
  RAISE EXCEPTION 'Gateway unexpectedly read telemetry';
 EXCEPTION WHEN insufficient_privilege THEN NULL; END;
 BEGIN
  PERFORM 1 FROM app.garments;
  RAISE EXCEPTION 'Gateway unexpectedly read wardrobe';
 EXCEPTION WHEN insufficient_privilege THEN NULL; END;
END $$;
SET LOCAL ROLE authenticated;
DO $$ BEGIN
 BEGIN
  PERFORM app.telemetry_prune();
  RAISE EXCEPTION 'App client unexpectedly obtained maintenance capability';
 EXCEPTION WHEN insufficient_privilege THEN NULL; END;
END $$;
RESET ROLE;
DO $$ BEGIN
 IF (SELECT count(*) FROM api_private.telemetry_events WHERE user_id='00000000-0000-0000-0000-000000000095') <> 1 THEN
  RAISE EXCEPTION 'Recent telemetry must survive maintenance';
 END IF;
END $$;
ROLLBACK;
