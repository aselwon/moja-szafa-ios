DO $$ BEGIN
  IF current_user<>'szafa_ai_worker' OR current_user=session_user
    OR pg_has_role(session_user,'service_role','MEMBER') THEN RAISE EXCEPTION 'Wrong worker role'; END IF;
  IF app.ai_worker_readiness()->>'enabled'<>'false' OR app.ai_worker_readiness()->>'image_enabled'<>'false'
    THEN RAISE EXCEPTION 'Deployment must remain disabled'; END IF;
  IF app.ai_worker_claim() IS NOT NULL THEN RAISE EXCEPTION 'Unexpected fixture job'; END IF;
  BEGIN PERFORM app.jobs_claim(); RAISE EXCEPTION 'Worker can bypass scoped claim';
    EXCEPTION WHEN insufficient_privilege THEN NULL; END;
  BEGIN PERFORM 1 FROM app.profiles; RAISE EXCEPTION 'Worker can read profiles';
    EXCEPTION WHEN insufficient_privilege THEN NULL; END;
  BEGIN PERFORM 1 FROM api_private.ai_policy; RAISE EXCEPTION 'Worker can read policy table';
    EXCEPTION WHEN insufficient_privilege THEN NULL; END;
  BEGIN UPDATE api_private.ai_policy SET enabled=true; RAISE EXCEPTION 'Worker can enable AI';
    EXCEPTION WHEN insufficient_privilege THEN NULL; END;
  BEGIN PERFORM app.api_v1_ai_consent('{}'); RAISE EXCEPTION 'Worker can impersonate consent';
    EXCEPTION WHEN insufficient_privilege THEN NULL; END;
  BEGIN PERFORM app.jobs_enqueue(gen_random_uuid(),gen_random_uuid(),'outfit_generation','{}',1); RAISE EXCEPTION 'Worker can enqueue for arbitrary owners';
    EXCEPTION WHEN insufficient_privilege THEN NULL; END;
END $$;
