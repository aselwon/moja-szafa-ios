-- Separate from consumer identities: operators never become app users.
CREATE SCHEMA ops_private;
REVOKE ALL ON SCHEMA ops_private FROM PUBLIC, anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA ops_private REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;

CREATE TABLE ops_private.operators (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 issuer text NOT NULL CHECK (length(issuer) BETWEEN 8 AND 512),
 subject text NOT NULL CHECK (length(subject) BETWEEN 1 AND 256),
 role text NOT NULL CHECK (role IN ('viewer','support','admin')),
 enabled boolean NOT NULL DEFAULT false,
 UNIQUE(issuer,subject)
);
-- Initial ceilings preserve the configured deployment budget. The panel cannot
-- raise them; an independently reviewed owner migration is needed to do that.
CREATE TABLE ops_private.control (
 singleton boolean PRIMARY KEY DEFAULT true CHECK(singleton),
 version bigint NOT NULL DEFAULT 1 CHECK(version>0),
 max_global_units integer NOT NULL CHECK(max_global_units>0),
 max_user_units integer NOT NULL CHECK(max_user_units>0)
);
INSERT INTO ops_private.control(singleton,max_global_units,max_user_units)
 SELECT true,daily_global_units,daily_user_units FROM api_private.ai_policy WHERE singleton;
CREATE TABLE ops_private.audit (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 occurred_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 operator_id uuid REFERENCES ops_private.operators(id),
 request_id uuid NOT NULL,
 action text NOT NULL,
 target_id uuid,
 outcome text NOT NULL CHECK(outcome IN ('allowed','denied','conflict')),
 request jsonb NOT NULL,
 before_value jsonb,
 after_value jsonb,
 response jsonb NOT NULL,
 UNIQUE(operator_id,request_id)
);
CREATE FUNCTION ops_private.immutable_audit() RETURNS trigger
LANGUAGE plpgsql SET search_path=pg_catalog AS $$ BEGIN
 RAISE EXCEPTION 'Operator audit is immutable' USING ERRCODE='42501';
END $$;
CREATE TRIGGER immutable_audit BEFORE UPDATE OR DELETE ON ops_private.audit
 FOR EACH ROW EXECUTE FUNCTION ops_private.immutable_audit();
REVOKE ALL ON ALL TABLES IN SCHEMA ops_private FROM PUBLIC,anon,authenticated,service_role;

CREATE FUNCTION ops_private.command(trusted_issuer text, trusted_subject text, request_id uuid, request jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
#variable_conflict use_column
<<operation>>
DECLARE actor ops_private.operators%ROWTYPE; previous ops_private.audit%ROWTYPE;
 action text:=request->>'action'; target uuid; result jsonb; input_request_id uuid:=request_id;
 prior jsonb; updated jsonb; outcome text:='allowed'; controls ops_private.control%ROWTYPE;
 support app.support_requests%ROWTYPE;
BEGIN
 -- Only the separately provisioned ops runtime can execute this function.
 -- Its authentication adapter verifies the JWT signature, issuer/audience and
 -- recent MFA before passing these identity values; JSON cannot choose an actor.
 IF request_id IS NULL OR jsonb_typeof(request) IS DISTINCT FROM 'object'
    OR octet_length(request::text)>4096 THEN
  RETURN '{"error":{"code":"invalid_request"}}';
 END IF;
 SELECT * INTO actor FROM ops_private.operators o
  WHERE o.issuer=trusted_issuer AND o.subject=trusted_subject AND o.enabled FOR SHARE;
 IF NOT FOUND THEN RETURN '{"error":{"code":"operator_denied"}}'; END IF;
 -- Serialize the same idempotency key before reading its audit record.
 PERFORM pg_advisory_xact_lock(hashtextextended(actor.id::text||request_id::text,0));
 SELECT * INTO previous FROM ops_private.audit a
  WHERE a.operator_id=actor.id AND a.request_id=operation.input_request_id;
 IF FOUND THEN
  IF previous.request=request THEN RETURN previous.response; END IF;
  RETURN '{"error":{"code":"idempotency_conflict"}}';
 END IF;
 IF action NOT IN ('summary','support_list','support_read','support_update','policy_update','audit_list') OR action IS NULL THEN
  RETURN '{"error":{"code":"invalid_request"}}';
 END IF;
 IF (action IN ('support_list','support_read','support_update') AND actor.role NOT IN ('support','admin'))
    OR (action IN ('policy_update','audit_list') AND actor.role<>'admin') THEN
  result:='{"error":{"code":"operator_denied"}}'; outcome:='denied';
 ELSIF action='summary' AND request=jsonb_build_object('action',action) THEN
  SELECT jsonb_build_object('generatedAt',clock_timestamp(),'database','ok','role',actor.role,
   'policy',(SELECT jsonb_build_object('version',c.version,'enabled',p.enabled,'imageEnabled',p.image_enabled,
     'dailyGlobalUnits',p.daily_global_units,'dailyUserUnits',p.daily_user_units,
     'maxGlobalUnits',c.max_global_units,'maxUserUnits',c.max_user_units)
     FROM api_private.ai_policy p CROSS JOIN ops_private.control c WHERE p.singleton AND c.singleton),
   'jobs',(SELECT coalesce(jsonb_agg(to_jsonb(j)),'[]') FROM (
     SELECT kind,status,count(*) AS count FROM app.ai_jobs WHERE deleted_at IS NULL
      AND (status IN ('queued','running','dead_letter') OR created_at>=clock_timestamp()-interval '30 days')
      GROUP BY kind,status ORDER BY kind,status) j),
   'images',(SELECT coalesce(jsonb_agg(to_jsonb(i)),'[]') FROM (
     SELECT state,count(*) AS count,count(*) FILTER(WHERE expires_at<clock_timestamp()) AS expired
     FROM api_private.image_uploads
     WHERE state IN ('pending','processing','retired') OR created_at>=clock_timestamp()-interval '30 days'
     GROUP BY state ORDER BY state) i),
   'deletions',(SELECT coalesce(jsonb_agg(to_jsonb(d)),'[]') FROM (
     SELECT status,count(*) AS count FROM app.deletion_jobs
     WHERE status IN ('queued','running','failed','dead_letter') OR created_at>=clock_timestamp()-interval '30 days'
     GROUP BY status ORDER BY status) d),
   'support',(SELECT coalesce(jsonb_agg(to_jsonb(s)),'[]') FROM (
     SELECT status,count(*) AS count FROM app.support_requests WHERE deleted_at IS NULL GROUP BY status ORDER BY status) s),
   'aiCalls',(SELECT coalesce(jsonb_agg(to_jsonb(d)),'[]') FROM (
     SELECT telemetry->>'provider' AS provider,telemetry->>'model' AS model,count(*)::text AS calls,
      count(*) FILTER(WHERE telemetry#>>'{usage,input_tokens}'~'^[0-9]{1,15}$' AND telemetry#>>'{usage,output_tokens}'~'^[0-9]{1,15}$')::text AS calls_with_usage,
      coalesce(sum(CASE WHEN telemetry#>>'{usage,input_tokens}'~'^[0-9]{1,15}$' AND telemetry#>>'{usage,output_tokens}'~'^[0-9]{1,15}$' THEN (telemetry#>>'{usage,input_tokens}')::numeric END),0)::text AS input_tokens,
      coalesce(sum(CASE WHEN telemetry#>>'{usage,input_tokens}'~'^[0-9]{1,15}$' AND telemetry#>>'{usage,output_tokens}'~'^[0-9]{1,15}$' THEN (telemetry#>>'{usage,output_tokens}')::numeric END),0)::text AS output_tokens
     FROM api_private.ai_dispatch_receipts WHERE dispatched_at>=clock_timestamp()-interval '30 days'
     GROUP BY 1,2 ORDER BY 1,2) d)) INTO updated;
  result:=jsonb_build_object('data',updated);
 ELSIF action='support_list' AND request=jsonb_build_object('action',action) THEN
  SELECT coalesce(jsonb_agg(to_jsonb(s)),'[]') INTO updated FROM (
   SELECT id,created_at,updated_at,version,status,left(subject,200) AS subject FROM app.support_requests
   WHERE deleted_at IS NULL ORDER BY created_at DESC,id LIMIT 100) s;
  result:=jsonb_build_object('data',updated);
 ELSIF action IN ('support_read','support_update') THEN
  IF request->>'id' !~* '^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$' OR request->>'id' IS NULL THEN
   RETURN '{"error":{"code":"invalid_request"}}';
  END IF;
  target:=(request->>'id')::uuid;
  SELECT * INTO support FROM app.support_requests WHERE id=target AND deleted_at IS NULL FOR UPDATE;
  IF NOT FOUND THEN result:='{"error":{"code":"not_found"}}'; outcome:='denied';
  ELSIF action='support_read' AND request-ARRAY['action','id']='{}'::jsonb THEN
   result:=jsonb_build_object('data',jsonb_build_object('id',support.id,'subject',left(support.subject,200),
    'message',left(support.message,16000),'truncated',length(support.message)>16000 OR length(support.subject)>200,
    'status',support.status,'version',support.version));
  ELSIF action='support_update' AND request-ARRAY['action','id','version','status']='{}'::jsonb
    AND jsonb_typeof(request->'version')='number' AND request->>'version'~'^[1-9][0-9]{0,17}$'
    AND request->>'status' IN ('open','in_progress','closed') THEN
   IF support.version<>(request->>'version')::bigint THEN
    result:='{"error":{"code":"version_conflict"}}'; outcome:='conflict';
   ELSE
    prior:=jsonb_build_object('status',support.status,'version',support.version);
    UPDATE app.support_requests SET status=request->>'status',version=version+1 WHERE id=target
     RETURNING jsonb_build_object('id',id,'status',status,'version',version) INTO updated;
    result:=jsonb_build_object('data',updated);
   END IF;
  ELSE RETURN '{"error":{"code":"invalid_request"}}'; END IF;
 ELSIF action='policy_update' THEN
  IF request-ARRAY['action','version','enabled','imageEnabled','dailyGlobalUnits','dailyUserUnits']<>'{}'::jsonb
   OR jsonb_typeof(request->'enabled') IS DISTINCT FROM 'boolean'
   OR jsonb_typeof(request->'imageEnabled') IS DISTINCT FROM 'boolean'
   OR jsonb_typeof(request->'version') IS DISTINCT FROM 'number'
   OR coalesce(request->>'version','') !~ '^[1-9][0-9]{0,17}$'
   OR jsonb_typeof(request->'dailyGlobalUnits') IS DISTINCT FROM 'number'
   OR jsonb_typeof(request->'dailyUserUnits') IS DISTINCT FROM 'number'
   OR coalesce(request->>'dailyGlobalUnits','') !~ '^[1-9][0-9]{0,6}$'
   OR coalesce(request->>'dailyUserUnits','') !~ '^[1-9][0-9]{0,6}$' THEN
   RETURN '{"error":{"code":"invalid_request"}}';
  END IF;
  SELECT * INTO controls FROM ops_private.control WHERE singleton FOR UPDATE;
  IF NOT FOUND THEN RETURN '{"error":{"code":"policy_unavailable"}}'; END IF;
  IF controls.version<>(request->>'version')::bigint THEN
   result:='{"error":{"code":"version_conflict"}}'; outcome:='conflict';
  ELSIF (request->>'dailyGlobalUnits')::integer>controls.max_global_units
     OR (request->>'dailyUserUnits')::integer>controls.max_user_units
     OR ((request->>'imageEnabled')::boolean AND NOT (request->>'enabled')::boolean) THEN
   result:='{"error":{"code":"policy_limit"}}'; outcome:='denied';
  ELSE
   SELECT jsonb_build_object('enabled',enabled,'imageEnabled',image_enabled,'dailyGlobalUnits',daily_global_units,
    'dailyUserUnits',daily_user_units,'version',controls.version) INTO prior FROM api_private.ai_policy WHERE singleton FOR UPDATE;
   IF NOT FOUND THEN RETURN '{"error":{"code":"policy_unavailable"}}'; END IF;
   UPDATE api_private.ai_policy SET enabled=(request->>'enabled')::boolean,image_enabled=(request->>'imageEnabled')::boolean,
    daily_global_units=(request->>'dailyGlobalUnits')::integer,daily_user_units=(request->>'dailyUserUnits')::integer WHERE singleton;
   UPDATE ops_private.control SET version=version+1 WHERE singleton RETURNING version INTO controls.version;
   updated:=(request-'action')||jsonb_build_object('version',controls.version);
   result:=jsonb_build_object('data',updated);
  END IF;
 ELSIF action='audit_list' AND request=jsonb_build_object('action',action) THEN
  SELECT coalesce(jsonb_agg(to_jsonb(a)),'[]') INTO updated FROM (
   SELECT id,occurred_at,operator_id,action,target_id,outcome,before_value,after_value
    FROM ops_private.audit ORDER BY occurred_at DESC,id LIMIT 100) a;
  result:=jsonb_build_object('data',updated);
 ELSE RETURN '{"error":{"code":"invalid_request"}}'; END IF;
 -- Reads are audited without duplicating support messages or report contents.
 -- Only write responses are cached for idempotency. Reads re-query on a new ID.
 INSERT INTO ops_private.audit(operator_id,request_id,action,target_id,outcome,request,before_value,after_value,response)
 VALUES(actor.id,request_id,action,target,outcome,request,prior,
  CASE WHEN action IN ('policy_update','support_update') THEN updated END,
  CASE WHEN action IN ('policy_update','support_update') THEN result ELSE '{"error":{"code":"request_already_used"}}'::jsonb END);
 RETURN result;
END $$;
REVOKE ALL ON FUNCTION ops_private.command(text,text,uuid,jsonb) FROM PUBLIC,anon,authenticated,service_role;
