-- Apply after neon-bootstrap.sql and app migrations. Separate trusted worker
-- login belongs ONLY to this role; never grant it to the HTTP gateway login.
DO $$ BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='szafa_erasure') THEN
    CREATE ROLE szafa_erasure NOLOGIN NOINHERIT;
  END IF;
END $$;
GRANT USAGE ON SCHEMA gateway_private TO szafa_erasure;

CREATE OR REPLACE FUNCTION gateway_private.erasure_command(request jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE
  action text := request->>'action';
  owner_id uuid := (request->>'owner')::uuid;
  job_id uuid := (coalesce(request->>'job',request->>'id'))::uuid;
  fence_id uuid := (request->>'fence')::uuid;
BEGIN
  IF action IN ('claim','retry') THEN RETURN app.deletion_command(request); END IF;
  -- Serialize each privileged step against lease replacement. Owner comes from
  -- the claimed durable queue, and must match its current fenced lease.
  PERFORM 1 FROM app.deletion_jobs j WHERE j.id=job_id AND j.user_id=owner_id
    AND j.status='running' AND j.lease_token=fence_id
    AND j.lease_expires_at>clock_timestamp() FOR UPDATE;
  IF NOT FOUND THEN
    IF action='assertLease' THEN RETURN 'false'::jsonb; END IF;
    RAISE EXCEPTION 'Active deletion lease required' USING ERRCODE='42501';
  END IF;
  IF action='assertLease' THEN RETURN 'true'::jsonb;
  ELSIF action='revokeSessions' THEN
    UPDATE neon_auth.session SET "expiresAt"=least("expiresAt",clock_timestamp()),"updatedAt"=clock_timestamp()
      WHERE "userId"=owner_id;
    RETURN 'true'::jsonb;
  ELSIF action='hasAppleIdentity' THEN
    RETURN to_jsonb(EXISTS (SELECT FROM neon_auth.account WHERE "userId"=owner_id AND "providerId"='apple'));
  ELSIF action='identityAbsent' THEN
    RETURN to_jsonb(NOT EXISTS (SELECT FROM neon_auth."user" WHERE id=owner_id));
  ELSIF action='approveDeletion' THEN
    PERFORM gateway_private.approve_identity_erasure(owner_id,job_id,fence_id);
    RETURN 'true'::jsonb;
  ELSIF action='imageIDs' THEN
    RETURN coalesce((SELECT jsonb_agg(id ORDER BY id) FROM api_private.image_uploads WHERE user_id=owner_id),'[]'::jsonb);
  ELSIF action='deferReplica' THEN
    -- An offline independent host is a prerequisite wait, not a destructive
    -- cleanup failure. Do not exhaust the eight-attempt cleanup budget overnight.
    UPDATE app.deletion_jobs SET status='queued',attempts=greatest(0,attempts-1),
      lease_token=NULL,lease_expires_at=NULL,available_at=clock_timestamp()+interval '5 minutes',
      error_code='backup_replica_unavailable' WHERE id=job_id;
    RETURN 'true'::jsonb;
  ELSIF action='finish' THEN
    -- The app's generic queue can delete its compatibility row itself. This
    -- deployment wrapper additionally requires actual managed identity absence.
    IF EXISTS (SELECT FROM neon_auth."user" WHERE id=owner_id) THEN
      RAISE EXCEPTION 'Managed identity remains' USING ERRCODE='42501';
    END IF;
    RETURN app.deletion_command(request);
  END IF;
  RAISE EXCEPTION 'Unsupported erasure operation' USING ERRCODE='42501';
END $$;
REVOKE ALL ON FUNCTION gateway_private.erasure_command(jsonb) FROM PUBLIC,anon,authenticated,szafa_gateway,service_role;
GRANT EXECUTE ON FUNCTION gateway_private.erasure_command(jsonb) TO szafa_erasure;
