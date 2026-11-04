BEGIN;
INSERT INTO auth.users VALUES ('00000000-0000-0000-0000-000000000093');
INSERT INTO app.profiles(id,user_id) VALUES ('00000000-0000-0000-0000-000000000093','00000000-0000-0000-0000-000000000093');
INSERT INTO api_private.ai_disclosure VALUES(true,'weather-test','Cloudflare Workers AI','Synthetic metadata','Synthetic test')
ON CONFLICT(singleton) DO UPDATE SET recipient=EXCLUDED.recipient,policy_version=EXCLUDED.policy_version;
INSERT INTO app.consent_events(user_id,purpose,policy_version,recipient,granted,client_request_id,disclosure)
SELECT '00000000-0000-0000-0000-000000000093','ai',policy_version,recipient,true,gen_random_uuid(),to_jsonb(d)-'singleton'
FROM api_private.ai_disclosure d;
UPDATE api_private.ai_policy SET enabled=true,daily_user_units=100,daily_global_units=100;
SELECT set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000093',true);
DO $$
DECLARE base jsonb := '{"count":3,"pinned_garment_id":null,"preferences":{"colors":[],"seasons":[]},"occasion":{"formality":null}}';
  payload jsonb; hint jsonb; result jsonb; job uuid;
BEGIN
  FOREACH hint IN ARRAY ARRAY['null'::jsonb,'{"source":"manual","temperature_celsius":-5.5}'::jsonb,
    jsonb_build_object('source','forecast','temperature_celsius',12,'valid_until',floor(extract(epoch from clock_timestamp()))+1800),
    '{"source":"forecast","temperature_celsius":12,"valid_until":1}'::jsonb]
  LOOP
    payload:=base||jsonb_build_object('operation_id',gen_random_uuid(),'weather',hint);
    result:=app.api_v1_generate_outfits(payload);
    job:=(result#>>'{data,job_id}')::uuid;
    IF job IS NULL THEN RAISE EXCEPTION 'Valid optional weather rejected: %',result; END IF;
    IF app.api_v1_generate_outfits(payload)#>>'{data,job_id}'<>job::text THEN RAISE EXCEPTION 'Weather replay duplicated job'; END IF;
    IF NOT EXISTS(SELECT FROM api_private.job_payloads p WHERE p.job_id=job AND p.input->'weather'=hint)
      THEN RAISE EXCEPTION 'Weather was not durably preserved'; END IF;
  END LOOP;
  FOREACH hint IN ARRAY ARRAY['{"source":null,"temperature_celsius":12,"valid_until":1}'::jsonb,
    '{"source":"manual","temperature_celsius":61}'::jsonb,
    '{"source":"manual","temperature_celsius":12,"city":"private"}'::jsonb,
    '{"source":"forecast","temperature_celsius":12}'::jsonb]
  LOOP
    result:=app.api_v1_generate_outfits(base||jsonb_build_object('operation_id',gen_random_uuid(),'weather',hint));
    IF result#>>'{error,code}' IS DISTINCT FROM 'validation_failed' THEN RAISE EXCEPTION 'Invalid weather accepted: %',result; END IF;
  END LOOP;
END $$;
ROLLBACK;
