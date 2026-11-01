-- T008 v2: additive upgrade from wardrobe v1; preserves existing rows.
BEGIN;
CREATE TABLE app.preferences (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id uuid NOT NULL REFERENCES app.profiles(id) ON DELETE CASCADE,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    version bigint NOT NULL DEFAULT 1 CHECK (version > 0),
    styles text[] NOT NULL DEFAULT '{}',
    preferred_colors text[] NOT NULL DEFAULT '{}',
    excluded_categories text[] NOT NULL DEFAULT '{}',
    notes text,
    UNIQUE (user_id),
    UNIQUE (user_id, id)
);

CREATE TABLE app.outfit_feedback (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id uuid NOT NULL REFERENCES app.profiles(id) ON DELETE CASCADE,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    version bigint NOT NULL DEFAULT 1 CHECK (version > 0),
    outfit_id uuid NOT NULL,
    rating text NOT NULL CHECK (rating IN ('useful','not_useful')),
    reason text,
    UNIQUE (user_id, outfit_id),
    UNIQUE (user_id, id),
    FOREIGN KEY (user_id, outfit_id) REFERENCES app.outfits(user_id, id) ON DELETE CASCADE
);

CREATE TABLE app.ai_jobs (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id uuid NOT NULL REFERENCES app.profiles(id) ON DELETE CASCADE,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    version bigint NOT NULL DEFAULT 1 CHECK (version > 0),
    operation_id uuid NOT NULL,
    kind text NOT NULL CHECK (kind IN ('classify','outfits','swap','trip','purchase')),
    status text NOT NULL DEFAULT 'queued' CHECK (status IN ('queued','running','succeeded','failed','cancelled','dead_letter','uncertain')),
    attempts integer NOT NULL DEFAULT 0 CHECK (attempts >= 0),
    max_attempts integer NOT NULL DEFAULT 3 CHECK (max_attempts > 0),
    available_at timestamptz NOT NULL DEFAULT now(),
    lease_token uuid,
    lease_expires_at timestamptz,
    model text,
    prompt_version text,
    pricing_version text,
    usage jsonb CHECK (jsonb_typeof(usage) = 'object'),
    cost_microunits bigint CHECK (cost_microunits >= 0),
    cost_currency text CHECK (cost_currency ~ '^[A-Z]{3}$'),
    latency_ms bigint CHECK (latency_ms >= 0),
    error_code text,
    CHECK (attempts <= max_attempts),
    CHECK ((status = 'running') = (lease_token IS NOT NULL AND lease_expires_at IS NOT NULL)),
    CHECK ((lease_token IS NULL) = (lease_expires_at IS NULL)),
    CHECK ((cost_microunits IS NULL) = (cost_currency IS NULL)),
    UNIQUE (user_id, operation_id),
    UNIQUE (user_id, id)
);

CREATE TABLE app.consent_events (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id uuid NOT NULL REFERENCES app.profiles(id) ON DELETE CASCADE,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    version bigint NOT NULL DEFAULT 1 CHECK (version > 0),
    purpose text NOT NULL CHECK (purpose IN ('ai','analytics','notifications')),
    policy_version text NOT NULL CHECK (length(btrim(policy_version)) > 0),
    recipient text,
    granted boolean NOT NULL,
    operation_id uuid NOT NULL,
    CHECK (purpose <> 'ai' OR length(btrim(recipient)) > 0 AND recipient IS NOT NULL),
    UNIQUE (user_id, operation_id),
    UNIQUE (user_id, id)
);

CREATE TABLE app.planned_outfits (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id uuid NOT NULL REFERENCES app.profiles(id) ON DELETE CASCADE,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    version bigint NOT NULL DEFAULT 1 CHECK (version > 0),
    outfit_id uuid NOT NULL,
    planned_on date NOT NULL,
    timezone text NOT NULL,
    notes text,
    deleted_at timestamptz,
    UNIQUE (user_id, outfit_id, planned_on),
    UNIQUE (user_id, id),
    FOREIGN KEY (user_id, outfit_id) REFERENCES app.outfits(user_id, id) ON DELETE CASCADE
);

CREATE TABLE app.trips (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id uuid NOT NULL REFERENCES app.profiles(id) ON DELETE CASCADE,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    version bigint NOT NULL DEFAULT 1 CHECK (version > 0),
    name text NOT NULL CHECK (length(btrim(name)) > 0),
    destination text NOT NULL,
    starts_on date NOT NULL,
    ends_on date NOT NULL,
    occasions text[] NOT NULL DEFAULT '{}',
    deleted_at timestamptz,
    CHECK (ends_on >= starts_on),
    UNIQUE (user_id, id)
);

CREATE TABLE app.trip_items (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id uuid NOT NULL REFERENCES app.profiles(id) ON DELETE CASCADE,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    version bigint NOT NULL DEFAULT 1 CHECK (version > 0),
    trip_id uuid NOT NULL,
    garment_id uuid NOT NULL,
    packed boolean NOT NULL DEFAULT false,
    UNIQUE (trip_id, garment_id),
    UNIQUE (user_id, id),
    FOREIGN KEY (user_id, trip_id) REFERENCES app.trips(user_id, id) ON DELETE CASCADE,
    FOREIGN KEY (user_id, garment_id) REFERENCES app.garments(user_id, id) ON DELETE CASCADE
);

CREATE TABLE app.purchase_candidates (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id uuid NOT NULL REFERENCES app.profiles(id) ON DELETE CASCADE,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    version bigint NOT NULL DEFAULT 1 CHECK (version > 0),
    object_key text NOT NULL UNIQUE,
    expires_at timestamptz NOT NULL,
    status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','analysed','purchased','discarded')),
    purchased_garment_id uuid,
    CHECK (expires_at > created_at),
    UNIQUE (user_id, id),
    FOREIGN KEY (user_id, purchased_garment_id) REFERENCES app.garments(user_id, id) ON DELETE SET NULL (purchased_garment_id)
);

CREATE TABLE app.subscription_entitlements (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id uuid NOT NULL REFERENCES app.profiles(id) ON DELETE CASCADE,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    version bigint NOT NULL DEFAULT 1 CHECK (version > 0),
    product_id text NOT NULL,
    original_transaction_id text NOT NULL UNIQUE,
    environment text NOT NULL CHECK (environment IN ('Sandbox','Production')),
    status text NOT NULL CHECK (status IN ('active','expired','revoked','grace_period','billing_retry')),
    expires_at timestamptz NOT NULL,
    verified_at timestamptz NOT NULL,
    UNIQUE (user_id),
    UNIQUE (user_id, id)
);

CREATE TABLE app.subscription_events (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id uuid NOT NULL REFERENCES app.profiles(id) ON DELETE CASCADE,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    version bigint NOT NULL DEFAULT 1 CHECK (version > 0),
    notification_id uuid NOT NULL UNIQUE,
    original_transaction_id text NOT NULL,
    event_type text NOT NULL,
    environment text NOT NULL CHECK (environment IN ('Sandbox','Production')),
    occurred_at timestamptz NOT NULL,
    processed_at timestamptz,
    UNIQUE (user_id, id)
);

CREATE TABLE app.usage_reservations (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id uuid NOT NULL REFERENCES app.profiles(id) ON DELETE CASCADE,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    version bigint NOT NULL DEFAULT 1 CHECK (version > 0),
    ai_job_id uuid NOT NULL,
    operation_id uuid NOT NULL,
    units integer NOT NULL CHECK (units > 0),
    status text NOT NULL DEFAULT 'reserved' CHECK (status IN ('reserved','settled','refunded')),
    expires_at timestamptz NOT NULL,
    CHECK (expires_at > created_at),
    UNIQUE (user_id, operation_id),
    UNIQUE (ai_job_id),
    UNIQUE (user_id, id),
    FOREIGN KEY (user_id, ai_job_id) REFERENCES app.ai_jobs(user_id, id) ON DELETE CASCADE
);

CREATE TABLE app.sync_operations (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id uuid NOT NULL REFERENCES app.profiles(id) ON DELETE CASCADE,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    version bigint NOT NULL DEFAULT 1 CHECK (version > 0),
    operation_id uuid NOT NULL,
    entity_type text NOT NULL CHECK (entity_type IN ('garment','outfit','wear_event','plan','trip','preference')),
    entity_id uuid NOT NULL,
    base_version bigint CHECK (base_version > 0),
    status text NOT NULL CHECK (status IN ('applied','conflict','deleted')),
    request_hash text NOT NULL CHECK (request_hash ~ '^[0-9a-f]{64}$'),
    result_version bigint CHECK (result_version > 0),
    UNIQUE (user_id, operation_id),
    UNIQUE (user_id, id)
);

-- No FK to auth/profiles: tombstone and cleanup job must survive account removal.
CREATE TABLE app.deletion_jobs (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id uuid NOT NULL UNIQUE,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    version bigint NOT NULL DEFAULT 1 CHECK (version > 0),
    operation_id uuid NOT NULL UNIQUE,
    status text NOT NULL DEFAULT 'queued' CHECK (status IN ('queued','running','completed','failed','dead_letter')),
    attempts integer NOT NULL DEFAULT 0 CHECK (attempts >= 0),
    available_at timestamptz NOT NULL DEFAULT now(),
    lease_token uuid,
    lease_expires_at timestamptz,
    completed_at timestamptz,
    error_code text,
    CHECK ((status = 'running') = (lease_token IS NOT NULL AND lease_expires_at IS NOT NULL)),
    CHECK ((lease_token IS NULL) = (lease_expires_at IS NULL)),
    CHECK ((status = 'completed') = (completed_at IS NOT NULL))
);

CREATE TABLE app.support_requests (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id uuid NOT NULL REFERENCES app.profiles(id) ON DELETE CASCADE,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    version bigint NOT NULL DEFAULT 1 CHECK (version > 0),
    operation_id uuid NOT NULL,
    subject text NOT NULL CHECK (length(btrim(subject)) > 0),
    message text NOT NULL CHECK (length(btrim(message)) > 0),
    status text NOT NULL DEFAULT 'open' CHECK (status IN ('open','in_progress','closed')),
    UNIQUE (user_id, operation_id),
    UNIQUE (user_id, id)
);

-- Server-only audit. No arbitrary payload, photographs, tokens or email addresses.
CREATE TABLE app.operator_audit (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    operator_id uuid NOT NULL,
    subject_user_id uuid,
    action text NOT NULL CHECK (length(btrim(action)) > 0),
    request_id uuid NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX ai_jobs_ready ON app.ai_jobs (available_at, id) WHERE status = 'queued';
CREATE INDEX ai_jobs_expired_lease ON app.ai_jobs (lease_expires_at) WHERE status = 'running';
CREATE INDEX consent_events_latest ON app.consent_events (user_id, purpose, created_at DESC, id);
CREATE INDEX planned_outfits_parent ON app.planned_outfits (user_id, outfit_id);
CREATE INDEX wear_events_source ON app.wear_events (user_id, source_outfit_id);
CREATE INDEX planned_outfits_day ON app.planned_outfits (user_id, planned_on) WHERE deleted_at IS NULL;
CREATE INDEX trip_items_garment ON app.trip_items (user_id, garment_id);
CREATE INDEX trips_dates ON app.trips (user_id, starts_on, ends_on);
CREATE INDEX candidates_expiry ON app.purchase_candidates (expires_at);
CREATE INDEX candidates_garment ON app.purchase_candidates (user_id, purchased_garment_id);
CREATE INDEX reservations_expiry ON app.usage_reservations (expires_at) WHERE status = 'reserved';
CREATE INDEX sync_operations_entity ON app.sync_operations (user_id, entity_type, entity_id);
CREATE INDEX deletion_jobs_ready ON app.deletion_jobs (available_at) WHERE status IN ('queued','failed');
CREATE INDEX operator_audit_subject ON app.operator_audit (subject_user_id, created_at);

DO $$
DECLARE t text;
BEGIN
    FOREACH t IN ARRAY ARRAY['preferences','outfit_feedback','ai_jobs','consent_events','planned_outfits','trips','trip_items','purchase_candidates','subscription_entitlements','subscription_events','usage_reservations','sync_operations','deletion_jobs','support_requests','operator_audit'] LOOP
        EXECUTE format('ALTER TABLE app.%I ENABLE ROW LEVEL SECURITY', t);
        EXECUTE format('ALTER TABLE app.%I FORCE ROW LEVEL SECURITY', t);
        EXECUTE format('REVOKE ALL ON app.%I FROM PUBLIC, authenticated', t);
        EXECUTE format('GRANT SELECT, INSERT ON app.%I TO service_role', t);
        IF t NOT IN ('operator_audit','consent_events') THEN
            EXECUTE format('GRANT UPDATE, DELETE ON app.%I TO service_role', t);
        END IF;
        IF t = 'deletion_jobs' THEN
            EXECUTE 'REVOKE DELETE ON app.deletion_jobs FROM service_role';
        END IF;
        IF t NOT IN ('operator_audit','subscription_events','deletion_jobs') THEN
            EXECUTE format('GRANT SELECT ON app.%I TO authenticated', t);
            EXECUTE format('CREATE POLICY owner_read ON app.%I FOR SELECT TO authenticated USING ((SELECT auth.uid()) = user_id)', t);
        END IF;
        IF t <> 'operator_audit' THEN
            EXECUTE format('CREATE TRIGGER touch_record BEFORE UPDATE ON app.%I FOR EACH ROW EXECUTE FUNCTION app.touch_record()', t);
        END IF;
    END LOOP;
END;
$$;

-- Account tombstones block stale writes even through the trusted service role.
CREATE FUNCTION app.reject_deleted_owner() RETURNS trigger LANGUAGE plpgsql
SET search_path = pg_catalog AS $$
DECLARE owner_id uuid;
BEGIN
    owner_id := (to_jsonb(NEW)->>CASE WHEN TG_TABLE_NAME = 'profiles' THEN 'id' ELSE 'user_id' END)::uuid;
    -- FK SET NULL actions may update a child while profile ON DELETE CASCADE
    -- is removing the same account. The absent parent plus its FK guarantees
    -- these rows cannot survive; do not obstruct account erasure.
    IF TG_OP = 'UPDATE' AND TG_TABLE_NAME <> 'profiles'
       AND NOT EXISTS (SELECT 1 FROM app.profiles WHERE id = owner_id) THEN
        RETURN NEW;
    END IF;
    -- Serialize writes with deletion job creation for this owner.
    PERFORM pg_advisory_xact_lock(hashtextextended(owner_id::text, 0));
    IF EXISTS (SELECT 1 FROM app.deletion_jobs WHERE user_id = owner_id) THEN
        RAISE EXCEPTION 'account deletion requested' USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END;
$$;
CREATE FUNCTION app.lock_deleted_owner() RETURNS trigger LANGUAGE plpgsql
SET search_path = pg_catalog AS $$
BEGIN
    PERFORM pg_advisory_xact_lock(hashtextextended(NEW.user_id::text, 0));
    RETURN NEW;
END;
$$;
CREATE TRIGGER lock_deleted_owner BEFORE INSERT ON app.deletion_jobs
FOR EACH ROW EXECUTE FUNCTION app.lock_deleted_owner();
DO $$
DECLARE t text;
BEGIN
    FOREACH t IN ARRAY ARRAY['profiles','garments','garment_images','outfits','outfit_items','wear_events','wear_event_items','preferences','outfit_feedback','ai_jobs','consent_events','planned_outfits','trips','trip_items','purchase_candidates','subscription_entitlements','subscription_events','usage_reservations','sync_operations','support_requests'] LOOP
        EXECUTE format('CREATE TRIGGER reject_deleted_owner BEFORE INSERT OR UPDATE ON app.%I FOR EACH ROW EXECUTE FUNCTION app.reject_deleted_owner()', t);
    END LOOP;
END;
$$;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA app FROM PUBLIC;
INSERT INTO app.schema_migrations (version) VALUES (2);
COMMIT;
