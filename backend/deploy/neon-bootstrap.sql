-- Provider compatibility for a Neon branch with Managed Better Auth enabled.
-- Apply before backend/migrate.sh, as the migration owner. No credentials in SQL.
-- This is NOT the CI auth shim: all principals reference real Managed Auth rows.
DO $$ BEGIN
  IF to_regclass('neon_auth.user') IS NULL OR to_regclass('neon_auth.session') IS NULL THEN
    RAISE EXCEPTION 'Managed Better Auth must be provisioned before bootstrap';
  END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='anon') THEN CREATE ROLE anon NOLOGIN; END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='authenticated') THEN CREATE ROLE authenticated NOLOGIN; END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='service_role') THEN CREATE ROLE service_role NOLOGIN; END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='szafa_gateway') THEN CREATE ROLE szafa_gateway NOLOGIN NOINHERIT; END IF;
END $$;

-- Reapply after migration 026. Only the gateway verifies Apple signatures;
-- authenticated clients never receive either privileged function grant.
DO $$ BEGIN
 IF to_regprocedure('app.apple_subscription_receive(jsonb)') IS NOT NULL THEN
  GRANT USAGE ON SCHEMA app TO szafa_gateway;
  GRANT EXECUTE ON FUNCTION app.apple_subscription_receive(jsonb),app.apple_subscription_status(uuid,text) TO szafa_gateway;
 END IF;
END $$;
GRANT authenticated TO szafa_gateway;
CREATE SCHEMA IF NOT EXISTS auth;
REVOKE ALL ON SCHEMA auth FROM PUBLIC;
CREATE TABLE IF NOT EXISTS auth.users (
  id uuid PRIMARY KEY REFERENCES neon_auth."user"(id) ON DELETE CASCADE
);
REVOKE ALL ON auth.users FROM PUBLIC, anon, authenticated, szafa_gateway;
CREATE OR REPLACE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS $$
  SELECT nullif(current_setting('request.jwt.claim.sub', true), '')::uuid
$$;
REVOKE ALL ON FUNCTION auth.uid() FROM PUBLIC;
GRANT USAGE ON SCHEMA auth TO authenticated;
GRANT EXECUTE ON FUNCTION auth.uid() TO authenticated;

CREATE SCHEMA IF NOT EXISTS gateway_private;
REVOKE ALL ON SCHEMA gateway_private FROM PUBLIC;
GRANT USAGE ON SCHEMA gateway_private TO szafa_gateway;
GRANT USAGE ON SCHEMA gateway_private TO service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA gateway_private REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
CREATE TABLE IF NOT EXISTS gateway_private.email_challenges (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  email text NOT NULL CHECK (length(email) BETWEEN 3 AND 254),
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  expires_at timestamptz NOT NULL DEFAULT clock_timestamp() + interval '5 minutes',
  attempts integer NOT NULL DEFAULT 0 CHECK (attempts BETWEEN 0 AND 5),
  consumed_at timestamptz
);
REVOKE ALL ON gateway_private.email_challenges FROM PUBLIC, anon, authenticated, szafa_gateway;
CREATE INDEX IF NOT EXISTS email_challenges_rate ON gateway_private.email_challenges(email,created_at);

-- Provider-native account deletion must not bypass the app's deletion journal
-- and private-photo cleanup. Only the separate trusted worker may authorize it.
CREATE TABLE IF NOT EXISTS gateway_private.identity_erasure_approvals (
  owner_id uuid PRIMARY KEY, job_id uuid NOT NULL, fence uuid NOT NULL,
  approved_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
REVOKE ALL ON gateway_private.identity_erasure_approvals FROM PUBLIC, anon, authenticated, szafa_gateway, service_role;
CREATE OR REPLACE FUNCTION gateway_private.approve_identity_erasure(p_owner_id uuid, p_job_id uuid, p_fence uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
  IF NOT EXISTS (SELECT FROM app.deletion_jobs j WHERE j.id=p_job_id AND j.user_id=p_owner_id
    AND j.status='running' AND j.lease_token=p_fence AND j.lease_expires_at>clock_timestamp())
    THEN RAISE EXCEPTION 'Active deletion lease required' USING ERRCODE='42501'; END IF;
  -- The worker calls this only AFTER independent journal and byte cleanup succeed.
  INSERT INTO gateway_private.identity_erasure_approvals(owner_id,job_id,fence)
    VALUES(p_owner_id,p_job_id,p_fence) ON CONFLICT(owner_id) DO UPDATE
    SET job_id=EXCLUDED.job_id,fence=EXCLUDED.fence,approved_at=clock_timestamp();
END $$;
CREATE OR REPLACE FUNCTION gateway_private.guard_identity_erasure() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
  IF NOT EXISTS (SELECT FROM gateway_private.identity_erasure_approvals a
    JOIN app.deletion_jobs j ON j.id=a.job_id AND j.user_id=a.owner_id
    WHERE a.owner_id=OLD.id AND a.fence=j.lease_token AND j.status='running'
      AND j.lease_expires_at>clock_timestamp() AND a.approved_at>clock_timestamp()-interval '5 minutes')
    THEN RAISE EXCEPTION 'App erasure authorization required before provider identity deletion' USING ERRCODE='42501'; END IF;
  DELETE FROM gateway_private.identity_erasure_approvals WHERE owner_id=OLD.id;
  RETURN OLD;
END $$;
DROP TRIGGER IF EXISTS gateway_identity_erasure_guard ON auth.users;
CREATE TRIGGER gateway_identity_erasure_guard BEFORE DELETE ON auth.users
  FOR EACH ROW EXECUTE FUNCTION gateway_private.guard_identity_erasure();

CREATE OR REPLACE FUNCTION gateway_private.start_email_challenge(address text) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE result uuid;
BEGIN
  IF address IS NULL OR length(address)>254 OR address !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'
    THEN RETURN NULL; END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended(address, 701));
  DELETE FROM gateway_private.email_challenges WHERE created_at < clock_timestamp()-interval '1 hour';
  IF (SELECT count(*) FROM gateway_private.email_challenges WHERE email=address) >= 3
     OR EXISTS (SELECT FROM gateway_private.email_challenges WHERE email=address AND created_at>clock_timestamp()-interval '60 seconds')
    THEN RETURN NULL; END IF;
  INSERT INTO gateway_private.email_challenges(email) VALUES(address) RETURNING id INTO result;
  RETURN result;
END $$;
CREATE OR REPLACE FUNCTION gateway_private.email_challenge_attempt(challenge uuid) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE address text;
BEGIN
  UPDATE gateway_private.email_challenges SET attempts=attempts+1
    WHERE id=challenge AND consumed_at IS NULL AND expires_at>clock_timestamp() AND attempts<5
    RETURNING email INTO address;
  RETURN address;
END $$;
CREATE OR REPLACE FUNCTION gateway_private.consume_email_challenge(challenge uuid) RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path=pg_catalog AS $$
  UPDATE gateway_private.email_challenges SET consumed_at=clock_timestamp() WHERE id=challenge
$$;

-- PL/pgSQL resolves app objects at execution time, after app migrations run.
CREATE OR REPLACE FUNCTION gateway_private.bind_session(owner_id uuid, session_id uuid) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
  -- Both provider identity and session must still exist at the transaction boundary.
  PERFORM 1 FROM neon_auth.session s JOIN neon_auth."user" u ON u.id=s."userId"
    WHERE s.id=session_id AND u.id=owner_id AND s."expiresAt">clock_timestamp()
      AND u."emailVerified"=true AND coalesce(u.banned,false)=false AND s."impersonatedBy" IS NULL
    FOR SHARE OF s,u;
  IF NOT FOUND OR EXISTS (SELECT FROM app.deletion_jobs WHERE user_id=owner_id) THEN RETURN false; END IF;
  INSERT INTO auth.users(id) VALUES(owner_id) ON CONFLICT DO NOTHING;
  INSERT INTO app.profiles(id,user_id) VALUES(owner_id,owner_id) ON CONFLICT DO NOTHING;
  PERFORM 1 FROM app.profiles WHERE user_id=owner_id AND deleted_at IS NULL FOR SHARE;
  IF NOT FOUND THEN RETURN false; END IF;
  PERFORM set_config('request.jwt.claim.sub',owner_id::text,true);
  PERFORM set_config('gateway.session_id',session_id::text,true);
  RETURN true;
END $$;

CREATE OR REPLACE FUNCTION gateway_private.resource_command(kind text, action text, payload jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE owner_id uuid := auth.uid(); result jsonb;
BEGIN
  IF NOT gateway_private.bind_session(owner_id,nullif(current_setting('gateway.session_id',true),'')::uuid)
    THEN RAISE EXCEPTION 'Session unavailable' USING ERRCODE='42501'; END IF;
  -- Owner and action always come from the validated request context, never caller JSON.
  payload := coalesce(payload,'{}'::jsonb) || jsonb_build_object('owner',owner_id,'action',action);
  IF kind='images' AND action IN ('prepare','claim','finish','read') THEN
    result := app.images_command(payload);
  ELSIF kind='purchase_images' AND action IN ('prepare','claim','finish','read') THEN
    result := app.purchase_images_command(payload);
  ELSIF kind='recognition_images' AND action IN ('prepare','claim','finish','read') THEN
    result := app.recognition_images_command(payload);
  ELSIF kind='exports' AND action IN ('prepare','check','read','image') THEN
    result := app.exports_command(payload);
  ELSE RAISE EXCEPTION 'Unsupported operation' USING ERRCODE='42501';
  END IF;
  RETURN result;
END $$;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA gateway_private FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION gateway_private.start_email_challenge(text),
  gateway_private.email_challenge_attempt(uuid), gateway_private.consume_email_challenge(uuid),
  gateway_private.bind_session(uuid,uuid), gateway_private.resource_command(text,text,jsonb) TO szafa_gateway;
GRANT EXECUTE ON FUNCTION gateway_private.approve_identity_erasure(uuid,uuid,uuid) TO service_role;
-- Create a separate LOGIN role belonging only to szafa_gateway through the secret
-- provisioning channel. Never run the public gateway as szafa_owner/service_role.

-- Reapply after migration 025. The gateway cannot read telemetry tables or
-- arbitrary accounts; it can only remove rows past their fixed retention age.
DO $$ BEGIN
 IF to_regprocedure('app.telemetry_prune()') IS NOT NULL THEN
  -- szafa_gateway is NOINHERIT: authenticated's namespace access is not inherited.
  -- USAGE only resolves this explicitly granted function; it grants no table reads.
  GRANT USAGE ON SCHEMA app TO szafa_gateway;
  GRANT EXECUTE ON FUNCTION app.telemetry_prune() TO szafa_gateway;
 END IF;
END $$;
