BEGIN;
CREATE FUNCTION pg_temp.assert_report(ok boolean,message text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF ok IS DISTINCT FROM true THEN RAISE EXCEPTION 'Observability report: %',message; END IF; END $$;
INSERT INTO auth.users VALUES('00000000-0000-0000-0000-000000000093');
INSERT INTO app.profiles(id,user_id,display_name) VALUES('00000000-0000-0000-0000-000000000093','00000000-0000-0000-0000-000000000093','PRIVATE_PERSON');
INSERT INTO api_private.telemetry_events(user_id,id,kind,data) VALUES('00000000-0000-0000-0000-000000000093',gen_random_uuid(),'api','{"route":"api_v1_save_garment","outcome":"success","durationMs":123}');
INSERT INTO app.ai_jobs(id,user_id,client_request_id,kind) VALUES('00000000-0000-0000-0000-000000000094','00000000-0000-0000-0000-000000000093',gen_random_uuid(),'outfit_generation');
INSERT INTO api_private.ai_dispatch_receipts(job_id,provider_call,attempt,units,telemetry) VALUES
 ('00000000-0000-0000-0000-000000000094',1,1,1,'{"provider":"cloudflare","model":"@cf/meta/llama-3.1-8b-instruct-fp8-fast","latency_ms":500,"usage":{"input_tokens":1000,"output_tokens":100},"status":"success"}'),
 ('00000000-0000-0000-0000-000000000094',2,1,1,NULL);
\set capture_observability_report true
\ir ../observability/report.sql
SELECT pg_temp.assert_report((:'report_jsonb_build_object'::jsonb#>>'{client_samples,0,p95_ms}')::numeric=123,'actual latency sample');
SELECT pg_temp.assert_report((SELECT sum((r->>'calls')::integer) FROM jsonb_array_elements(:'report_jsonb_build_object'::jsonb->'ai_calls')r)=2,'all dispatched calls counted');
SELECT pg_temp.assert_report((SELECT sum((r->>'calls_with_usage')::integer) FROM jsonb_array_elements(:'report_jsonb_build_object'::jsonb->'ai_calls')r)=1,'missing usage remains distinct');
SELECT pg_temp.assert_report(position('PRIVATE_PERSON' IN :'report_jsonb_build_object')=0 AND position('00000000-0000-0000-0000-000000000093' IN :'report_jsonb_build_object')=0,'operator aggregates contain no owner/profile identifiers');
ROLLBACK;
