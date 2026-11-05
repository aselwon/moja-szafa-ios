-- Owner/operator-only reporting connection. No identifiers, payloads, email,
-- wardrobe content, auth records or raw diagnostic frames are returned here.
SELECT jsonb_build_object(
 'generated_at',clock_timestamp(),
 'client_samples',(SELECT coalesce(jsonb_agg(to_jsonb(r)),'[]'::jsonb) FROM (
  SELECT (received_at AT TIME ZONE 'UTC')::date AS day,kind,
   CASE WHEN kind IN('api','sync') THEN data->>'route' ELSE NULL END AS route,
   CASE WHEN kind IN('api','sync') THEN data->>'outcome' ELSE NULL END AS outcome,
   count(*) AS samples,
   percentile_cont(0.95) WITHIN GROUP(ORDER BY (data->>'durationMs')::double precision) FILTER(WHERE kind IN('api','sync')) AS p95_ms
  FROM api_private.telemetry_events WHERE received_at>=clock_timestamp()-interval '30 days'
  GROUP BY 1,2,3,4 ORDER BY 1,2,3,4) r),
 'consenting_accounts',(SELECT jsonb_build_object('diagnostics',count(*) FILTER(WHERE diagnostics),'product',count(*) FILTER(WHERE product)) FROM api_private.telemetry_preferences),
 'activation',(SELECT jsonb_build_object('wardrobe_5',count(*) FILTER(WHERE kind='wardrobe_5'),'outfits_3',count(*) FILTER(WHERE kind='outfits_3'))
  FROM api_private.telemetry_events WHERE kind IN('wardrobe_5','outfits_3') AND received_at>=clock_timestamp()-interval '30 days'),
 'jobs',(SELECT coalesce(jsonb_agg(to_jsonb(r)),'[]'::jsonb) FROM (
  SELECT kind,status,count(*) AS jobs,
   percentile_cont(0.95) WITHIN GROUP(ORDER BY extract(epoch FROM finished_at-created_at)*1000) FILTER(WHERE finished_at IS NOT NULL) AS end_to_end_p95_ms
  FROM app.ai_jobs WHERE created_at>=clock_timestamp()-interval '30 days' AND deleted_at IS NULL GROUP BY 1,2 ORDER BY 1,2) r),
 'ai_calls',(SELECT coalesce(jsonb_agg(to_jsonb(r)),'[]'::jsonb) FROM (
  SELECT (d.dispatched_at AT TIME ZONE 'UTC')::date AS day,d.telemetry->>'provider' AS provider,d.telemetry->>'model' AS model,
   count(*)::text AS calls,
   count(*) FILTER(WHERE d.telemetry#>>'{usage,input_tokens}'~'^[0-9]{1,15}$' AND d.telemetry#>>'{usage,output_tokens}'~'^[0-9]{1,15}$')::text AS calls_with_usage,
   coalesce(sum(CASE WHEN d.telemetry#>>'{usage,input_tokens}'~'^[0-9]{1,15}$' AND d.telemetry#>>'{usage,output_tokens}'~'^[0-9]{1,15}$' THEN (d.telemetry#>>'{usage,input_tokens}')::numeric END),0)::text AS input_tokens,
   coalesce(sum(CASE WHEN d.telemetry#>>'{usage,input_tokens}'~'^[0-9]{1,15}$' AND d.telemetry#>>'{usage,output_tokens}'~'^[0-9]{1,15}$' THEN (d.telemetry#>>'{usage,output_tokens}')::numeric END),0)::text AS output_tokens,
   percentile_cont(0.95) WITHIN GROUP(ORDER BY CASE WHEN d.telemetry->>'latency_ms'~'^[0-9]{1,10}$' THEN (d.telemetry->>'latency_ms')::double precision END) AS provider_p95_ms
  FROM api_private.ai_dispatch_receipts d WHERE d.dispatched_at>=clock_timestamp()-interval '30 days' GROUP BY 1,2,3 ORDER BY 1,2,3) r),
 'ai_policy',(SELECT jsonb_build_object('enabled',enabled,'image_enabled',image_enabled,'daily_global_call_credit_limit',daily_global_units,
  'daily_user_call_credit_limit',daily_user_units,'dispatched_call_credits_today',coalesce((SELECT units FROM api_private.ai_daily_dispatch WHERE day=(clock_timestamp() AT TIME ZONE 'UTC')::date),0)) FROM api_private.ai_policy WHERE singleton),
 'coverage','Client samples include opted-in devices only. Crash diagnostics depend on OS delivery and matching retained symbols. Counts do not establish a crash-free-session percentage.'
);

-- Optional psql capture used by the transactional integration test.
\if :{?capture_observability_report}
\gset report_
\endif
