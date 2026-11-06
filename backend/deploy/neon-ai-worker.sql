-- Apply transactionally AFTER app migration016. Does not enable AI or vision.
DO $$ BEGIN
  IF to_regprocedure('app.ai_runtime_dispatch(uuid,uuid,text)') IS NULL THEN
    RAISE EXCEPTION 'AI runtime migration016 required';
  END IF;
  IF NOT EXISTS(SELECT FROM pg_roles WHERE rolname='szafa_ai_worker') THEN
    CREATE ROLE szafa_ai_worker NOLOGIN NOINHERIT NOBYPASSRLS NOSUPERUSER NOCREATEDB NOCREATEROLE;
  END IF;
  IF EXISTS(SELECT FROM pg_roles WHERE rolname='szafa_ai_worker' AND
    (rolcanlogin OR rolinherit OR rolbypassrls OR rolsuper OR rolcreatedb OR rolcreaterole)) THEN
    RAISE EXCEPTION 'Unsafe AI worker role configuration';
  END IF;
END $$;
GRANT USAGE ON SCHEMA app TO szafa_ai_worker;
REVOKE ALL ON FUNCTION app.jobs_claim() FROM szafa_ai_worker;
GRANT EXECUTE ON FUNCTION app.jobs_authorize_dispatch(uuid,uuid),
  app.jobs_finish(uuid,uuid,text,jsonb),app.ai_runtime_input(uuid,uuid),
  app.ai_runtime_dispatch(uuid,uuid,text),app.ai_runtime_telemetry(uuid,integer,integer,jsonb)
  TO szafa_ai_worker;

CREATE OR REPLACE FUNCTION app.ai_worker_readiness() RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog AS $$
  SELECT jsonb_build_object('enabled',p.enabled,'image_enabled',p.image_enabled,
    'recipient',p.recipient,'daily_user_units',p.daily_user_units,'daily_global_units',p.daily_global_units,
    'disclosure_matches',EXISTS(SELECT FROM api_private.ai_disclosure d WHERE d.recipient=p.recipient),
    'unsupported_jobs_pending',EXISTS(SELECT FROM app.ai_jobs WHERE kind<>'outfit_generation' AND status IN('queued','running')))
  FROM api_private.ai_policy p WHERE singleton
$$;
REVOKE ALL ON FUNCTION app.ai_worker_readiness() FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION app.ai_worker_readiness() TO szafa_ai_worker;
-- Provision a separate LOGIN NOINHERIT NOBYPASSRLS role through the secret
-- channel, then GRANT szafa_ai_worker to it. Never grant service_role, gateway
-- membership, table access, consent or enqueue functions to this login.

-- Serialize this brief claim with queue writes: a non-outfit job arriving after
-- startup must never be consumed by a runtime that cannot execute it.
CREATE OR REPLACE FUNCTION app.ai_worker_claim() RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
  LOCK TABLE app.ai_jobs IN SHARE ROW EXCLUSIVE MODE;
  IF NOT EXISTS(SELECT FROM api_private.ai_policy WHERE singleton AND enabled AND NOT image_enabled) THEN RETURN NULL; END IF;
  IF EXISTS(SELECT FROM app.ai_jobs WHERE kind<>'outfit_generation' AND status IN('queued','running')) THEN
    RETURN NULL;
  END IF;
  RETURN app.jobs_claim();
END $$;
REVOKE ALL ON FUNCTION app.ai_worker_claim() FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION app.ai_worker_claim() TO szafa_ai_worker;

-- Image-capable deployment uses an explicit claim entry point. The legacy
-- text-only worker continues to reject image policy and cannot consume images.
CREATE OR REPLACE FUNCTION app.ai_image_worker_readiness() RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog AS $$
 SELECT app.ai_worker_readiness() || jsonb_build_object('unsupported_jobs_pending',
   EXISTS(SELECT FROM app.ai_jobs WHERE kind NOT IN('outfit_generation','image_analysis')
     AND status IN('queued','running')))
$$;
CREATE OR REPLACE FUNCTION app.ai_image_worker_claim() RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
 LOCK TABLE app.ai_jobs IN SHARE ROW EXCLUSIVE MODE;
 IF NOT EXISTS(SELECT FROM api_private.ai_policy WHERE singleton AND enabled AND image_enabled)
   THEN RETURN NULL; END IF;
 IF EXISTS(SELECT FROM app.ai_jobs WHERE kind NOT IN('outfit_generation','image_analysis')
   AND status IN('queued','running')) THEN RETURN NULL; END IF;
 RETURN app.jobs_claim();
END $$;
REVOKE ALL ON FUNCTION app.ai_image_worker_readiness(),app.ai_image_worker_claim()
 FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION app.ai_image_worker_readiness(),app.ai_image_worker_claim() TO szafa_ai_worker;
