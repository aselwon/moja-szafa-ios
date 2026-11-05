BEGIN;
CREATE FUNCTION pg_temp.assert_ops(ok boolean, message text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF ok IS DISTINCT FROM true THEN RAISE EXCEPTION 'Operations assertion: %',message; END IF; END $$;
INSERT INTO ops_private.operators(id,issuer,subject,role,enabled) VALUES
 ('54000000-0000-0000-0000-000000000001','https://operator.example','viewer','viewer',true),
 ('54000000-0000-0000-0000-000000000002','https://operator.example','support','support',true),
 ('54000000-0000-0000-0000-000000000003','https://operator.example','admin','admin',true),
 ('54000000-0000-0000-0000-000000000004','https://operator.example','disabled','admin',false);
INSERT INTO auth.users VALUES('54000000-0000-0000-0000-000000000005');
INSERT INTO app.profiles(id,user_id) VALUES('54000000-0000-0000-0000-000000000005','54000000-0000-0000-0000-000000000005');
INSERT INTO app.support_requests(id,user_id,client_request_id,subject,message,status) VALUES
 ('54000000-0000-0000-0000-000000000006','54000000-0000-0000-0000-000000000005',gen_random_uuid(),
 'Synthetic support subject','PRIVATE SUPPORT MESSAGE','open');
DO $$ DECLARE r jsonb; payload jsonb; request_id uuid:=gen_random_uuid(); audit_count integer; BEGIN
 r:=ops_private.command('https://operator.example','viewer',gen_random_uuid(),'{"action":"summary"}');
 PERFORM pg_temp.assert_ops(r#>>'{data,database}'='ok','overview');
 PERFORM pg_temp.assert_ops(NOT r::text LIKE '%PRIVATE SUPPORT%' AND NOT r::text LIKE '%54000000%','overview excludes user content and identity');
 PERFORM pg_temp.assert_ops(ops_private.command('https://evil.example','admin',gen_random_uuid(),'{"action":"summary"}')#>>'{error,code}'='operator_denied','issuer bound');
 PERFORM pg_temp.assert_ops(ops_private.command('https://operator.example','disabled',gen_random_uuid(),'{"action":"summary"}')#>>'{error,code}'='operator_denied','disabled operator');
 PERFORM pg_temp.assert_ops(ops_private.command('https://operator.example','viewer',gen_random_uuid(),'{"action":"support_list"}')#>>'{error,code}'='operator_denied','viewer cannot read support');
 PERFORM pg_temp.assert_ops(ops_private.command('https://operator.example','support',gen_random_uuid(),'{"action":"audit_list"}')#>>'{error,code}'='operator_denied','support cannot read audit');
 payload:='{"action":"policy_update","version":1,"enabled":false,"imageEnabled":false,"dailyGlobalUnits":1,"dailyUserUnits":1}';
 PERFORM pg_temp.assert_ops(ops_private.command('https://operator.example','support',gen_random_uuid(),payload)#>>'{error,code}'='operator_denied','support cannot change flags');
 r:=ops_private.command('https://operator.example','admin',request_id,payload);
 PERFORM pg_temp.assert_ops(r#>>'{data,version}'='2','admin update increments version');
 SELECT count(*) INTO audit_count FROM ops_private.audit;
 PERFORM pg_temp.assert_ops(ops_private.command('https://operator.example','admin',request_id,payload)=r,'exact write replay');
 PERFORM pg_temp.assert_ops((SELECT count(*) FROM ops_private.audit)=audit_count,'replay no duplicate audit');
 PERFORM pg_temp.assert_ops(ops_private.command('https://operator.example','admin',request_id,payload||'{"enabled":true}')#>>'{error,code}'='idempotency_conflict','changed replay denied');
 PERFORM pg_temp.assert_ops(ops_private.command('https://operator.example','admin',gen_random_uuid(),payload)#>>'{error,code}'='version_conflict','stale config denied');
 PERFORM pg_temp.assert_ops(ops_private.command('https://operator.example','admin',gen_random_uuid(),payload||'{"version":2,"dailyGlobalUnits":1000000}')#>>'{error,code}'='policy_limit','budget ceiling retained');
 PERFORM pg_temp.assert_ops((SELECT daily_global_units=1 AND NOT enabled FROM api_private.ai_policy WHERE singleton),'denials cannot change policy');
 r:=ops_private.command('https://operator.example','support',gen_random_uuid(),'{"action":"support_read","id":"54000000-0000-0000-0000-000000000006"}');
 PERFORM pg_temp.assert_ops(r#>>'{data,message}'='PRIVATE SUPPORT MESSAGE','authorized explicit support read');
 payload:='{"action":"support_update","id":"54000000-0000-0000-0000-000000000006","version":1,"status":"in_progress"}';
 r:=ops_private.command('https://operator.example','support',gen_random_uuid(),payload);
 PERFORM pg_temp.assert_ops(r#>>'{data,version}'='2' AND r#>>'{data,status}'='in_progress','support status CAS');
 PERFORM pg_temp.assert_ops(ops_private.command('https://operator.example','support',gen_random_uuid(),payload)#>>'{error,code}'='version_conflict','stale support status denied');
 PERFORM pg_temp.assert_ops(NOT EXISTS(SELECT FROM ops_private.audit WHERE to_jsonb(audit)::text LIKE '%PRIVATE SUPPORT MESSAGE%'),'audit excludes support text');
 BEGIN UPDATE ops_private.audit SET outcome='failed'; RAISE EXCEPTION 'audit update unexpectedly allowed';
 EXCEPTION WHEN insufficient_privilege THEN NULL; END;
 BEGIN DELETE FROM ops_private.audit; RAISE EXCEPTION 'audit delete unexpectedly allowed';
 EXCEPTION WHEN insufficient_privilege THEN NULL; END;
 UPDATE ops_private.operators SET enabled=false WHERE subject='support';
 PERFORM pg_temp.assert_ops(ops_private.command('https://operator.example','support',gen_random_uuid(),payload)#>>'{error,code}'='operator_denied','revocation immediate');
END $$;
CREATE FUNCTION pg_temp.fail_audit() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'synthetic audit outage'; END $$;
CREATE TRIGGER fail_audit BEFORE INSERT ON ops_private.audit FOR EACH ROW EXECUTE FUNCTION pg_temp.fail_audit();
DO $$ BEGIN
 BEGIN
  PERFORM ops_private.command('https://operator.example','admin',gen_random_uuid(),'{"action":"policy_update","version":2,"enabled":true,"imageEnabled":false,"dailyGlobalUnits":1,"dailyUserUnits":1}');
  RAISE EXCEPTION 'audit outage unexpectedly ignored';
 EXCEPTION WHEN raise_exception THEN
  IF SQLERRM<>'synthetic audit outage' THEN RAISE; END IF;
 END;
 PERFORM pg_temp.assert_ops((SELECT NOT enabled FROM api_private.ai_policy WHERE singleton),'audit failure rolls back flag write');
 PERFORM pg_temp.assert_ops((SELECT version=2 FROM ops_private.control WHERE singleton),'audit failure rolls back version');
END $$;
DROP TRIGGER fail_audit ON ops_private.audit;
SELECT pg_temp.assert_ops(NOT has_function_privilege('authenticated','ops_private.command(text,text,uuid,jsonb)','EXECUTE'),'consumer denied');
SELECT pg_temp.assert_ops(NOT has_function_privilege('service_role','ops_private.command(text,text,uuid,jsonb)','EXECUTE'),'consumer backend denied');
SELECT pg_temp.assert_ops(NOT has_schema_privilege('authenticated','ops_private','USAGE'),'private operator namespace');
ROLLBACK;
