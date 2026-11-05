BEGIN;
CREATE FUNCTION pg_temp.assert_subscription(ok boolean,message text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF ok IS DISTINCT FROM true THEN RAISE EXCEPTION 'Subscription assertion: %',message; END IF; END $$;
INSERT INTO auth.users VALUES('00000000-0000-4000-8000-000000000081'),('00000000-0000-4000-8000-000000000082');
INSERT INTO app.profiles(id,user_id) SELECT id,id FROM auth.users WHERE id IN('00000000-0000-4000-8000-000000000081','00000000-0000-4000-8000-000000000082');
CREATE FUNCTION pg_temp.apple_event(transaction_id text,purchased_seconds integer,expires_seconds integer) RETURNS jsonb LANGUAGE sql AS $$
 SELECT jsonb_build_object('source','transaction','eventID',gen_random_uuid(),'digest',repeat('a',64),'eventType','TRANSACTION',
 'eventSignedAt',floor(extract(epoch FROM statement_timestamp())*1000),
 'transaction',jsonb_build_object('environment','sandbox','owner','00000000-0000-4000-8000-000000000081','transactionID',transaction_id,
 'originalTransactionID','1000','productID','test.monthly','purchasedAt',floor(extract(epoch FROM statement_timestamp()+purchased_seconds*interval '1 second')*1000),
 'expiresAt',floor(extract(epoch FROM statement_timestamp()+expires_seconds*interval '1 second')*1000),
 'signedAt',floor(extract(epoch FROM statement_timestamp())*1000),'revokedAt',null,'upgraded',false),'renewal',null);
$$;
DO $$ DECLARE first jsonb; renewal jsonb; expired jsonb; revoked jsonb; result jsonb; event jsonb; BEGIN
 first:=pg_temp.apple_event('1000',-7200,3600);
 result:=app.apple_subscription_receive(first);
 PERFORM pg_temp.assert_subscription(result#>>'{entitlement,status}'='active','purchase grants active state');
 PERFORM pg_temp.assert_subscription(app.apple_subscription_receive(first)->>'duplicate'='true','exact retry is deduplicated');
 PERFORM pg_temp.assert_subscription((SELECT count(*) FROM app.subscription_events WHERE user_id='00000000-0000-4000-8000-000000000081')=1,'retry does not duplicate history');
 BEGIN
  PERFORM app.apple_subscription_receive(jsonb_set(first,'{digest}',to_jsonb(repeat('b',64))));
  RAISE EXCEPTION 'Accepted conflicting event';
 EXCEPTION WHEN invalid_parameter_value THEN NULL; END;
 BEGIN
  event:=jsonb_set(pg_temp.apple_event('1001',-3600,7200),'{transaction,owner}','"00000000-0000-4000-8000-000000000082"');
  PERFORM app.apple_subscription_receive(event); RAISE EXCEPTION 'Accepted foreign owner';
 EXCEPTION WHEN invalid_parameter_value THEN NULL; END;
 renewal:=pg_temp.apple_event('1001',-3600,7200);
 PERFORM app.apple_subscription_receive(renewal);
 -- Refund of an older billing transaction must not revoke a later renewal.
 revoked:=jsonb_set(first,'{eventID}',to_jsonb(gen_random_uuid()));
 revoked:=jsonb_set(revoked,'{transaction,revokedAt}',first#>'{transaction,signedAt}');
 result:=app.apple_subscription_receive(revoked);
 PERFORM pg_temp.assert_subscription(result#>>'{entitlement,status}'='active','old refund cannot revoke current renewal');
 -- A newer expired billing period supersedes the old period even if the old
 -- receipt claimed a later expiration. Access is recomputed from database time.
 expired:=pg_temp.apple_event('1002',-1800,-1);
 result:=app.apple_subscription_receive(expired);
 PERFORM pg_temp.assert_subscription(result#>>'{entitlement,status}'='expired','database clock expires latest period');
 PERFORM app.apple_subscription_receive(jsonb_set(first,'{eventID}',to_jsonb(gen_random_uuid())));
 PERFORM pg_temp.assert_subscription(app.apple_subscription_status('00000000-0000-4000-8000-000000000081','sandbox')#>>'{0,status}'='expired','old replay cannot resurrect expired period');
 event:=jsonb_set(expired,'{eventID}',to_jsonb(gen_random_uuid()));
 event:=event||jsonb_build_object('source','notification','eventType','DID_FAIL_TO_RENEW','renewal',jsonb_build_object(
  'signedAt',floor(extract(epoch FROM statement_timestamp())*1000),'graceExpiresAt',floor(extract(epoch FROM statement_timestamp()+interval '1 hour')*1000),'billingRetry',true,'autoRenew',true));
 result:=app.apple_subscription_receive(event);
 PERFORM pg_temp.assert_subscription(result#>>'{entitlement,status}'='grace_period','verified grace interval permits access');
 event:=jsonb_set(event,'{eventID}',to_jsonb(gen_random_uuid()));
 event:=jsonb_set(event,'{renewal,signedAt}',to_jsonb((event#>>'{renewal,signedAt}')::numeric+1));
 event:=jsonb_set(event,'{renewal,graceExpiresAt}',expired#>'{transaction,expiresAt}');
 result:=app.apple_subscription_receive(event);
 PERFORM pg_temp.assert_subscription(result#>>'{entitlement,status}'='billing_retry','expired grace does not grant paid access during billing retry');
 revoked:=jsonb_set(expired,'{eventID}',to_jsonb(gen_random_uuid()));
 revoked:=jsonb_set(revoked,'{transaction,revokedAt}',expired#>'{transaction,signedAt}');
 result:=app.apple_subscription_receive(revoked);
 PERFORM pg_temp.assert_subscription(result#>>'{entitlement,status}'='revoked','current refund wins over grace');
 PERFORM app.apple_subscription_receive(jsonb_set(expired,'{eventID}',to_jsonb(gen_random_uuid())));
 PERFORM pg_temp.assert_subscription(app.apple_subscription_status('00000000-0000-4000-8000-000000000081','sandbox')#>>'{0,status}'='revoked','same timestamp replay cannot undo revocation');
 event:=jsonb_set(expired,'{eventID}',to_jsonb(gen_random_uuid()))||'{"source":"notification","eventType":"REFUND_REVERSED"}';
 event:=jsonb_set(event,'{transaction,signedAt}',to_jsonb((expired#>>'{transaction,signedAt}')::numeric+1));
 result:=app.apple_subscription_receive(event);
 PERFORM pg_temp.assert_subscription(result#>>'{entitlement,status}'='billing_retry','new verified refund reversal clears revocation without inventing unexpired access');
 event:=jsonb_set(first,'{transaction,environment}','"production"');
 event:=jsonb_set(event,'{eventID}',to_jsonb(gen_random_uuid()));
 result:=app.apple_subscription_receive(event);
 PERFORM pg_temp.assert_subscription(result#>>'{entitlement,status}'='active','same numeric transaction IDs remain environment isolated');
 PERFORM pg_temp.assert_subscription(jsonb_array_length(app.apple_subscription_status('00000000-0000-4000-8000-000000000082','sandbox'))=0,'foreign account has no entitlement');
 PERFORM pg_temp.assert_subscription(jsonb_array_length(api_private.export_snapshot('00000000-0000-4000-8000-000000000081')->'apple_subscription_transactions')=4,'export includes own normalized transactions');
 PERFORM pg_temp.assert_subscription(jsonb_array_length(api_private.export_snapshot('00000000-0000-4000-8000-000000000082')->'apple_subscription_transactions')=0,'export isolates owners');
END $$;
SELECT pg_temp.assert_subscription(NOT has_function_privilege('authenticated','app.apple_subscription_receive(jsonb)','EXECUTE'),'client cannot fabricate a verified transaction');
SELECT pg_temp.assert_subscription(NOT has_function_privilege('authenticated','app.apple_subscription_status(uuid,text)','EXECUTE'),'client cannot read another owner through privileged function');
SELECT pg_temp.assert_subscription(NOT has_table_privilege('authenticated','api_private.apple_subscription_transactions','UPDATE'),'client cannot patch access');
DELETE FROM app.profiles WHERE user_id='00000000-0000-4000-8000-000000000081';
SELECT pg_temp.assert_subscription(NOT EXISTS(SELECT FROM api_private.apple_subscription_chains) AND NOT EXISTS(SELECT FROM api_private.apple_subscription_transactions) AND NOT EXISTS(SELECT FROM api_private.apple_subscription_receipts),'erasure cascades the full ledger');
SELECT pg_temp.assert_subscription(app.apple_subscription_receive(pg_temp.apple_event('1000',-7200,3600))->>'error'='account_unavailable','replayed webhook never recreates erased account');
ROLLBACK;
