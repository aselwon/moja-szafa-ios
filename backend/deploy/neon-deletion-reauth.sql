-- Managed OTP reauthentication bridge. No OTP/password/session token is stored.
-- Apply after neon-bootstrap.sql and app migrations, before enabling the route.
CREATE TABLE IF NOT EXISTS gateway_private.deletion_challenges (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  owner_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  session_id uuid NOT NULL,
  email text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  expires_at timestamptz NOT NULL DEFAULT clock_timestamp()+interval '5 minutes',
  attempts integer NOT NULL DEFAULT 0 CHECK(attempts BETWEEN 0 AND 5),
  operation_id uuid,
  consumed_at timestamptz,
  receipt jsonb
);
REVOKE ALL ON gateway_private.deletion_challenges FROM PUBLIC,anon,authenticated,szafa_gateway,service_role,szafa_erasure;
CREATE INDEX IF NOT EXISTS deletion_challenge_owner_time ON gateway_private.deletion_challenges(owner_id,created_at);

-- Minimal capability receipts survive provider/user cascade deletion. Only the
-- hash of a random read-only receipt token is retained; it cannot request erasure.
CREATE TABLE IF NOT EXISTS gateway_private.deletion_receipts (
  challenge_id uuid PRIMARY KEY,
  owner_id uuid NOT NULL,
  session_id uuid NOT NULL,
  token_hash text NOT NULL CHECK(token_hash ~ '^[a-f0-9]{64}$'),
  operation_id uuid,
  accepted boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
REVOKE ALL ON gateway_private.deletion_receipts FROM PUBLIC,anon,authenticated,szafa_gateway,service_role,szafa_erasure;

CREATE OR REPLACE FUNCTION gateway_private.create_deletion_receipt(p_owner uuid,p_session uuid,p_challenge uuid,p_hash text)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
  IF p_hash IS NULL OR p_hash !~ '^[a-f0-9]{64}$' THEN RETURN false; END IF;
  PERFORM 1 FROM gateway_private.deletion_challenges WHERE id=p_challenge AND owner_id=p_owner AND session_id=p_session
    AND consumed_at IS NULL AND expires_at>clock_timestamp() FOR UPDATE;
  IF NOT FOUND OR NOT gateway_private.bind_session(p_owner,p_session) THEN RETURN false; END IF;
  INSERT INTO gateway_private.deletion_receipts(challenge_id,owner_id,session_id,token_hash)
    VALUES(p_challenge,p_owner,p_session,p_hash) ON CONFLICT DO NOTHING;
  RETURN EXISTS(SELECT FROM gateway_private.deletion_receipts WHERE challenge_id=p_challenge AND token_hash=p_hash);
END $$;
CREATE OR REPLACE FUNCTION gateway_private.deletion_receipt_status(p_challenge uuid,p_operation uuid,p_hash text)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog AS $$
  SELECT EXISTS(SELECT FROM gateway_private.deletion_receipts WHERE challenge_id=p_challenge
    AND operation_id=p_operation AND token_hash=p_hash AND accepted=true);
$$;
REVOKE ALL ON FUNCTION gateway_private.create_deletion_receipt(uuid,uuid,uuid,text),gateway_private.deletion_receipt_status(uuid,uuid,text)
  FROM PUBLIC,anon,authenticated,service_role,szafa_erasure;
GRANT EXECUTE ON FUNCTION gateway_private.create_deletion_receipt(uuid,uuid,uuid,text),gateway_private.deletion_receipt_status(uuid,uuid,text) TO szafa_gateway;

CREATE OR REPLACE FUNCTION gateway_private.deletion_reauthentication(
  action text,p_owner uuid,p_session uuid,p_challenge uuid DEFAULT NULL,
  p_operation uuid DEFAULT NULL,p_fresh_session uuid DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE
  address text;
  challenge gateway_private.deletion_challenges%ROWTYPE;
  accepted jsonb;
BEGIN
  -- This narrow route may acknowledge an already accepted operation while the
  -- original managed session is still live. All other routes reject tombstones.
  SELECT lower(trim(u.email)) INTO address FROM neon_auth."user" u
    JOIN neon_auth.session s ON s."userId"=u.id
    WHERE u.id=p_owner AND s.id=p_session AND s."expiresAt">clock_timestamp()
      AND u."emailVerified"=true AND coalesce(u.banned,false)=false AND s."impersonatedBy" IS NULL
    FOR SHARE OF u,s;
  IF NOT FOUND THEN RETURN NULL; END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended(p_owner::text,1701));
  IF action='start' THEN
    IF NOT gateway_private.bind_session(p_owner,p_session) THEN RETURN NULL; END IF;
    -- Apple identity revocation is not configured; never accept an unfinishable deletion.
    IF EXISTS(SELECT FROM neon_auth.account WHERE "userId"=p_owner AND "providerId"='apple') THEN RETURN NULL; END IF;
    DELETE FROM gateway_private.deletion_receipts r WHERE r.accepted=false AND r.created_at<clock_timestamp()-interval '1 day';
    DELETE FROM gateway_private.deletion_challenges WHERE consumed_at IS NULL
      AND expires_at<clock_timestamp() AND created_at<clock_timestamp()-interval '1 day';
    IF (SELECT count(*) FROM gateway_private.deletion_challenges WHERE owner_id=p_owner AND created_at>clock_timestamp()-interval '1 hour')>=3
      OR EXISTS(SELECT FROM gateway_private.deletion_challenges WHERE owner_id=p_owner AND created_at>clock_timestamp()-interval '60 seconds')
      THEN RETURN NULL; END IF;
    UPDATE gateway_private.deletion_challenges SET expires_at=clock_timestamp() WHERE owner_id=p_owner AND consumed_at IS NULL;
    INSERT INTO gateway_private.deletion_challenges(owner_id,session_id,email) VALUES(p_owner,p_session,address) RETURNING * INTO challenge;
    RETURN jsonb_build_object('id',challenge.id,'email',address);
  END IF;
  SELECT * INTO challenge FROM gateway_private.deletion_challenges WHERE id=p_challenge AND owner_id=p_owner
    AND session_id=p_session AND email=address FOR UPDATE;
  IF NOT FOUND OR p_operation IS NULL
    OR (challenge.operation_id IS NOT NULL AND challenge.operation_id<>p_operation) THEN RETURN NULL; END IF;
  IF challenge.consumed_at IS NOT NULL THEN RETURN jsonb_build_object('receipt',challenge.receipt); END IF;
  IF challenge.expires_at<=clock_timestamp() THEN RETURN NULL; END IF;
  IF NOT gateway_private.bind_session(p_owner,p_session) THEN RETURN NULL; END IF;
  IF action='attempt' THEN
    IF challenge.attempts>=5 THEN RETURN NULL; END IF;
    UPDATE gateway_private.deletion_challenges SET attempts=attempts+1,operation_id=p_operation WHERE id=p_challenge;
    RETURN jsonb_build_object('email',address);
  ELSIF action='accept' THEN
    IF challenge.operation_id IS DISTINCT FROM p_operation OR challenge.attempts<1 OR p_fresh_session=p_session THEN RETURN NULL; END IF;
    IF EXISTS(SELECT FROM neon_auth.account WHERE "userId"=p_owner AND "providerId"='apple') THEN RETURN NULL; END IF;
    -- The caller cannot submit a session ID. Gateway supplies the live managed
    -- session returned by an OTP exchange and independently checked /get-session.
    PERFORM 1 FROM neon_auth.session s WHERE s.id=p_fresh_session AND s."userId"=p_owner
      AND s."createdAt">=challenge.created_at AND s."expiresAt">clock_timestamp()
      AND s."impersonatedBy" IS NULL FOR UPDATE;
    IF NOT FOUND THEN RETURN NULL; END IF;
    accepted := app.deletion_command(jsonb_build_object('action','request','owner',p_owner,'id',p_operation));
    IF accepted IS NULL OR accepted='null'::jsonb THEN RETURN NULL; END IF;
    UPDATE gateway_private.deletion_challenges SET consumed_at=clock_timestamp(),receipt=accepted WHERE id=p_challenge;
    UPDATE gateway_private.deletion_receipts SET accepted=true,operation_id=p_operation WHERE challenge_id=p_challenge
      AND owner_id=p_owner AND session_id=p_session;
    -- The temporary proof session is never returned to the client or left live.
    UPDATE neon_auth.session SET "expiresAt"=least("expiresAt",clock_timestamp()),"updatedAt"=clock_timestamp() WHERE id=p_fresh_session;
    RETURN jsonb_build_object('receipt',accepted);
  END IF;
  RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION gateway_private.deletion_reauthentication(text,uuid,uuid,uuid,uuid,uuid) FROM PUBLIC,anon,authenticated,service_role,szafa_erasure;
GRANT EXECUTE ON FUNCTION gateway_private.deletion_reauthentication(text,uuid,uuid,uuid,uuid,uuid) TO szafa_gateway;
