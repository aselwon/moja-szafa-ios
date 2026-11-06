BEGIN;
INSERT INTO auth.users VALUES('00000000-0000-0000-0000-000000000099');
INSERT INTO app.profiles(id,user_id) VALUES('00000000-0000-0000-0000-000000000099','00000000-0000-0000-0000-000000000099');
INSERT INTO app.ai_jobs(id,user_id,client_request_id,kind)
 VALUES('00000000-0000-0000-0000-000000000098','00000000-0000-0000-0000-000000000099',gen_random_uuid(),'image_analysis');
INSERT INTO api_private.job_payloads(job_id,input)
 VALUES('00000000-0000-0000-0000-000000000098','{}');
INSERT INTO app.usage_reservations(user_id,ai_job_id,client_request_id,units,expires_at)
 SELECT user_id,id,client_request_id,1,now()+interval '1 hour' FROM app.ai_jobs;
SET LOCAL ROLE szafa_ai_worker;
DO $$ BEGIN
 IF app.ai_image_worker_claim() IS NOT NULL THEN RAISE EXCEPTION 'Disabled image claimed'; END IF;
END $$;
RESET ROLE;
UPDATE api_private.ai_policy SET enabled=true,image_enabled=true;
SET LOCAL ROLE szafa_ai_worker;
DO $$ DECLARE job jsonb; BEGIN
 IF app.ai_worker_claim() IS NOT NULL THEN RAISE EXCEPTION 'Legacy worker claimed image'; END IF;
 job:=app.ai_image_worker_claim();
 IF job->>'kind' IS DISTINCT FROM 'image_analysis' THEN RAISE EXCEPTION 'Image not claimed'; END IF;
 IF app.ai_image_worker_claim() IS NOT NULL THEN RAISE EXCEPTION 'Duplicate claim'; END IF;
END $$;
RESET ROLE;
INSERT INTO app.ai_jobs(user_id,client_request_id,kind)
 VALUES('00000000-0000-0000-0000-000000000099',gen_random_uuid(),'trip');
SET LOCAL ROLE szafa_ai_worker;
DO $$ BEGIN
 IF app.ai_image_worker_readiness()->>'unsupported_jobs_pending' <> 'true'
 OR app.ai_image_worker_claim() IS NOT NULL THEN RAISE EXCEPTION 'Unsupported kind accepted'; END IF;
END $$;
ROLLBACK;

-- Two failed outfits reserve four calls but dispatch only three. The last real
-- unit remains available to vision; a fifth dispatch/admission is still denied.
BEGIN;
INSERT INTO auth.users VALUES('00000000-0000-0000-0000-000000000099');
INSERT INTO app.profiles(id,user_id) VALUES('00000000-0000-0000-0000-000000000099','00000000-0000-0000-0000-000000000099');
UPDATE api_private.ai_policy SET enabled=true,image_enabled=true,daily_user_units=4,daily_global_units=10;
INSERT INTO api_private.ai_disclosure VALUES(true,'image-test','Cloudflare Workers AI','Synthetic thumbnail','Synthetic test')
 ON CONFLICT(singleton) DO UPDATE SET recipient=EXCLUDED.recipient,policy_version=EXCLUDED.policy_version;
INSERT INTO app.consent_events(user_id,purpose,policy_version,recipient,granted,client_request_id,disclosure)
 SELECT '00000000-0000-0000-0000-000000000099','ai',d.policy_version,d.recipient,true,gen_random_uuid(),to_jsonb(d)-'singleton'
 FROM api_private.ai_disclosure d;
DO $$ DECLARE owner uuid:='00000000-0000-0000-0000-000000000099'; job uuid; lease jsonb; BEGIN
 FOR i IN 1..2 LOOP
  job:=app.jobs_enqueue(owner,gen_random_uuid(),'outfit_generation','{}');lease:=app.jobs_claim();
  IF NOT app.ai_runtime_dispatch(job,(lease->>'lease_token')::uuid,'Cloudflare Workers AI') THEN RAISE EXCEPTION 'First call denied'; END IF;
  IF i=2 THEN
   PERFORM app.ai_runtime_telemetry(job,1,1,'{"status":"outfit_json_invalid"}');
   IF NOT app.ai_runtime_dispatch(job,(lease->>'lease_token')::uuid,'Cloudflare Workers AI') THEN RAISE EXCEPTION 'Repair denied'; END IF;
  END IF;
  PERFORM app.jobs_finish(job,(lease->>'lease_token')::uuid,'permanent');
 END LOOP;
 job:=app.jobs_enqueue(owner,gen_random_uuid(),'image_analysis','{}');lease:=app.ai_image_worker_claim();
 IF NOT app.ai_runtime_dispatch(job,(lease->>'lease_token')::uuid,'Cloudflare Workers AI') THEN RAISE EXCEPTION 'Remaining real unit unavailable'; END IF;
 PERFORM app.jobs_finish(job,(lease->>'lease_token')::uuid,'permanent');
 BEGIN PERFORM app.jobs_enqueue(owner,gen_random_uuid(),'image_analysis','{}');RAISE EXCEPTION 'Fifth call admitted';
 EXCEPTION WHEN invalid_parameter_value THEN NULL; END;
 IF (SELECT units FROM api_private.ai_daily_dispatch WHERE day=(clock_timestamp() AT TIME ZONE 'UTC')::date)<>4 THEN RAISE EXCEPTION 'Spend was reset'; END IF;
END $$;
ROLLBACK;
