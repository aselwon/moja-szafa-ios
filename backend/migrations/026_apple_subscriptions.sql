-- T050: only the gateway's verified Apple adapter can write this ledger.
-- No client supplied clock, boolean or decoded unsigned receipt grants access.
ALTER TABLE app.subscription_entitlements DROP CONSTRAINT subscription_entitlements_original_transaction_id_key;
ALTER TABLE app.subscription_entitlements ADD UNIQUE(environment,original_transaction_id);

CREATE TABLE api_private.apple_subscription_chains (
 environment text NOT NULL CHECK(environment IN('sandbox','production')),
 original_id text NOT NULL CHECK(original_id ~ '^[1-9][0-9]{0,31}$'),
 user_id uuid NOT NULL REFERENCES app.profiles(user_id) ON DELETE CASCADE,
 renewal_signed_at timestamptz NOT NULL DEFAULT '-infinity',
 grace_expires_at timestamptz, billing_retry boolean NOT NULL DEFAULT false,
 auto_renew boolean NOT NULL DEFAULT false,
 PRIMARY KEY(environment,original_id), UNIQUE(environment,original_id,user_id)
);
CREATE TABLE api_private.apple_subscription_transactions (
 environment text NOT NULL, transaction_id text NOT NULL CHECK(transaction_id ~ '^[1-9][0-9]{0,31}$'),
 original_id text NOT NULL, user_id uuid NOT NULL,
 product_id text NOT NULL, purchased_at timestamptz NOT NULL, expires_at timestamptz NOT NULL,
 signed_at timestamptz NOT NULL, revoked_at timestamptz, upgraded boolean NOT NULL,
 PRIMARY KEY(environment,transaction_id),
 FOREIGN KEY(environment,original_id,user_id) REFERENCES api_private.apple_subscription_chains(environment,original_id,user_id) ON DELETE CASCADE,
 CHECK(expires_at>purchased_at)
);
CREATE INDEX apple_subscription_latest ON api_private.apple_subscription_transactions(environment,original_id,purchased_at DESC);
CREATE TABLE api_private.apple_subscription_receipts (
 environment text NOT NULL, event_id uuid NOT NULL, original_id text NOT NULL, user_id uuid NOT NULL,
 digest text NOT NULL CHECK(digest ~ '^[a-f0-9]{64}$'),
 received_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 PRIMARY KEY(environment,event_id),
 FOREIGN KEY(environment,original_id,user_id) REFERENCES api_private.apple_subscription_chains(environment,original_id,user_id) ON DELETE CASCADE
);
REVOKE ALL ON api_private.apple_subscription_chains,api_private.apple_subscription_transactions,api_private.apple_subscription_receipts FROM PUBLIC,anon,authenticated,service_role;

CREATE FUNCTION api_private.apple_subscription_state(p_environment text,p_original_id text) RETURNS jsonb
LANGUAGE sql STABLE SET search_path=pg_catalog AS $$
 SELECT jsonb_build_object('productID',t.product_id,'originalTransactionID',t.original_id,
  'environment',t.environment,'expiresAt',t.expires_at,
  'graceExpiresAt',CASE WHEN c.renewal_signed_at>=t.purchased_at THEN c.grace_expires_at END,
  'status',CASE
   WHEN t.revoked_at IS NOT NULL OR t.upgraded THEN 'revoked'
   WHEN t.expires_at>statement_timestamp() THEN 'active'
   WHEN c.renewal_signed_at>=t.purchased_at AND c.grace_expires_at>statement_timestamp() THEN 'grace_period'
   WHEN c.renewal_signed_at>=t.purchased_at AND c.billing_retry THEN 'billing_retry'
   ELSE 'expired' END)
 FROM api_private.apple_subscription_chains c
 JOIN LATERAL (SELECT * FROM api_private.apple_subscription_transactions x
  WHERE x.environment=c.environment AND x.original_id=c.original_id
  ORDER BY x.purchased_at DESC,x.transaction_id::numeric DESC LIMIT 1) t ON true
 WHERE c.environment=p_environment AND c.original_id=p_original_id;
$$;
REVOKE ALL ON FUNCTION api_private.apple_subscription_state(text,text) FROM PUBLIC,anon,authenticated,service_role;

CREATE FUNCTION app.apple_subscription_receive(request jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
#variable_conflict use_column
<<receipt>>
DECLARE t jsonb:=request->'transaction'; r jsonb:=request->'renewal';
 env text:=t->>'environment'; owner_id uuid:=(t->>'owner')::uuid;
 original_id text:=t->>'originalTransactionID'; transaction_id text:=t->>'transactionID';
 event_id uuid:=(request->>'eventID')::uuid; digest text:=request->>'digest';
 existing api_private.apple_subscription_receipts%ROWTYPE; chain api_private.apple_subscription_chains%ROWTYPE;
 prior api_private.apple_subscription_transactions%ROWTYPE; state jsonb; entitlement_id uuid;
 purchased timestamptz:=to_timestamp((t->>'purchasedAt')::numeric/1000);
 expires timestamptz:=to_timestamp((t->>'expiresAt')::numeric/1000);
 signed timestamptz:=to_timestamp((t->>'signedAt')::numeric/1000);
 revoked timestamptz:=to_timestamp((t->>'revokedAt')::numeric/1000);
BEGIN
 IF owner_id IS NULL OR env IS NULL OR env NOT IN('sandbox','production') OR event_id IS NULL OR
  original_id IS NULL OR transaction_id IS NULL OR original_id !~ '^[1-9][0-9]{0,31}$' OR transaction_id !~ '^[1-9][0-9]{0,31}$' OR
  digest IS NULL OR digest !~ '^[a-f0-9]{64}$' OR request->>'source' NOT IN('transaction','notification') OR
  coalesce(t->>'productID','') !~ '^[A-Za-z0-9][A-Za-z0-9._-]{2,199}$' OR
  purchased IS NULL OR expires IS NULL OR signed IS NULL OR expires<=purchased OR
  purchased>clock_timestamp()+interval '5 minutes' OR signed>clock_timestamp()+interval '5 minutes' OR
  jsonb_typeof(t->'upgraded') IS DISTINCT FROM 'boolean' THEN RAISE EXCEPTION 'invalid_subscription_event' USING ERRCODE='22023'; END IF;
 -- This lock serializes receipt delivery with account deletion. It never creates
 -- an identity, including when Apple retries a notification after erasure.
 PERFORM 1 FROM app.profiles WHERE user_id=owner_id AND deleted_at IS NULL FOR SHARE;
 IF NOT FOUND OR EXISTS(SELECT FROM app.deletion_jobs WHERE user_id=owner_id) THEN RETURN jsonb_build_object('error','account_unavailable'); END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended('apple:'||env||':'||original_id,0));
 IF EXISTS(SELECT FROM app.subscription_entitlements e WHERE e.environment=env AND e.original_transaction_id=original_id AND e.user_id<>owner_id) THEN
  RAISE EXCEPTION 'subscription_account_mismatch' USING ERRCODE='22023';
 END IF;
 INSERT INTO api_private.apple_subscription_chains(environment,original_id,user_id) VALUES(env,original_id,owner_id) ON CONFLICT DO NOTHING;
 SELECT * INTO chain FROM api_private.apple_subscription_chains c WHERE c.environment=env AND c.original_id=receipt.original_id FOR UPDATE;
 IF chain.user_id<>owner_id THEN RAISE EXCEPTION 'subscription_account_mismatch' USING ERRCODE='22023'; END IF;
 SELECT * INTO existing FROM api_private.apple_subscription_receipts e WHERE e.environment=env AND e.event_id=receipt.event_id;
 IF FOUND THEN
  IF existing.digest<>digest OR existing.user_id<>owner_id OR existing.original_id<>original_id THEN RAISE EXCEPTION 'subscription_event_conflict' USING ERRCODE='22023'; END IF;
  RETURN jsonb_build_object('transactionID',transaction_id,'duplicate',true,'entitlement',api_private.apple_subscription_state(env,original_id));
 END IF;
 SELECT * INTO prior FROM api_private.apple_subscription_transactions x WHERE x.environment=env AND x.transaction_id=receipt.transaction_id;
 IF FOUND AND (prior.user_id<>owner_id OR prior.original_id<>original_id OR prior.product_id<>t->>'productID' OR prior.purchased_at<>purchased) THEN
  RAISE EXCEPTION 'subscription_transaction_conflict' USING ERRCODE='22023';
 END IF;
 INSERT INTO api_private.apple_subscription_transactions AS stored(environment,transaction_id,original_id,user_id,product_id,purchased_at,expires_at,signed_at,revoked_at,upgraded)
 VALUES(env,transaction_id,original_id,owner_id,t->>'productID',purchased,expires,signed,revoked,(t->>'upgraded')::boolean)
 ON CONFLICT(environment,transaction_id) DO UPDATE SET
  expires_at=excluded.expires_at,signed_at=excluded.signed_at,
  revoked_at=CASE WHEN request->>'eventType'='REFUND_REVERSED' AND excluded.signed_at>stored.signed_at
   THEN excluded.revoked_at ELSE coalesce(excluded.revoked_at,stored.revoked_at) END,
  upgraded=excluded.upgraded OR stored.upgraded
 WHERE excluded.signed_at>=stored.signed_at AND stored.user_id=excluded.user_id AND stored.original_id=excluded.original_id;
 IF r IS NOT NULL AND r<>'null'::jsonb THEN
  UPDATE api_private.apple_subscription_chains c SET renewal_signed_at=to_timestamp((r->>'signedAt')::numeric/1000),
   grace_expires_at=to_timestamp((r->>'graceExpiresAt')::numeric/1000),billing_retry=(r->>'billingRetry')::boolean,auto_renew=(r->>'autoRenew')::boolean
  WHERE c.environment=env AND c.original_id=receipt.original_id AND c.renewal_signed_at<to_timestamp((r->>'signedAt')::numeric/1000);
 END IF;
 INSERT INTO api_private.apple_subscription_receipts VALUES(env,event_id,original_id,owner_id,digest,clock_timestamp());
 state:=api_private.apple_subscription_state(env,original_id);
 INSERT INTO app.subscription_entitlements AS e(user_id,original_transaction_id,product_id,status,expires_at,verified_at,environment)
 VALUES(owner_id,original_id,state->>'productID',state->>'status',(state->>'expiresAt')::timestamptz,clock_timestamp(),env)
 ON CONFLICT(environment,original_transaction_id) DO UPDATE SET product_id=excluded.product_id,status=excluded.status,expires_at=excluded.expires_at,verified_at=excluded.verified_at
 RETURNING id INTO entitlement_id;
 -- Public history is append-only. The private environment-scoped dedupe above
 -- remains authoritative even if a provider reuses a UUID across environments.
 INSERT INTO app.subscription_events(user_id,notification_id,entitlement_id,event_type,occurred_at)
 VALUES(owner_id,gen_random_uuid(),entitlement_id,request->>'eventType',to_timestamp((request->>'eventSignedAt')::numeric/1000));
 RETURN jsonb_build_object('transactionID',transaction_id,'duplicate',false,'entitlement',state);
END;
$$;
REVOKE ALL ON FUNCTION app.apple_subscription_receive(jsonb) FROM PUBLIC,anon,authenticated,service_role;

-- Read through this function, not the historical projection's cached status:
-- expiry changes with the database clock even without another Apple webhook.
CREATE FUNCTION app.apple_subscription_status(owner_id uuid,env text) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog AS $$
 SELECT coalesce(jsonb_agg(api_private.apple_subscription_state(c.environment,c.original_id)),'[]'::jsonb)
 FROM api_private.apple_subscription_chains c
 JOIN app.profiles p ON p.user_id=c.user_id AND p.deleted_at IS NULL
 WHERE c.user_id=owner_id AND c.environment=env
 AND NOT EXISTS(SELECT FROM app.deletion_jobs WHERE user_id=owner_id);
$$;
REVOKE ALL ON FUNCTION app.apple_subscription_status(uuid,text) FROM PUBLIC,anon,authenticated,service_role;

ALTER FUNCTION api_private.export_snapshot(uuid) RENAME TO export_snapshot_pre026;
CREATE FUNCTION api_private.export_snapshot(owner_id uuid) RETURNS jsonb
LANGUAGE sql STABLE SET search_path=pg_catalog AS $$
 SELECT api_private.export_snapshot_pre026(owner_id)||jsonb_build_object(
  'apple_subscription_chains',coalesce((SELECT jsonb_agg(to_jsonb(c)-'user_id') FROM api_private.apple_subscription_chains c WHERE c.user_id=owner_id),'[]'::jsonb),
  'apple_subscription_transactions',coalesce((SELECT jsonb_agg(to_jsonb(t)-'user_id') FROM api_private.apple_subscription_transactions t WHERE t.user_id=owner_id),'[]'::jsonb),
  'apple_subscription_receipts',coalesce((SELECT jsonb_agg(to_jsonb(r)-'user_id') FROM api_private.apple_subscription_receipts r WHERE r.user_id=owner_id),'[]'::jsonb));
$$;
REVOKE ALL ON FUNCTION api_private.export_snapshot(uuid),api_private.export_snapshot_pre026(uuid) FROM PUBLIC,anon,authenticated,service_role;
