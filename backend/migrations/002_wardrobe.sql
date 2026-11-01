-- All relationships carry user_id, including joins and optional references.
-- No client writes: atomic mutations and server-managed state go through T009 API.

CREATE TABLE app.garments (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id uuid NOT NULL REFERENCES app.profiles(user_id) ON DELETE CASCADE,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    version bigint NOT NULL DEFAULT 1 CHECK (version > 0),
    deleted_at timestamptz,
    name text NOT NULL CHECK (length(btrim(name)) > 0),
category text NOT NULL CHECK (category IN ('top','bottom','shoes','dress','jumpsuit','outerwear','accessory','other')),
subcategory text, colors text[] NOT NULL DEFAULT '{}', pattern text,
seasons text[] NOT NULL DEFAULT '{}' CHECK (seasons <@ ARRAY['spring','summer','autumn','winter']),
formality smallint CHECK (formality BETWEEN 1 AND 5),
price_grosz bigint CHECK (price_grosz >= 0), currency text NOT NULL DEFAULT 'PLN' CHECK (currency = 'PLN'),
brand text, purchased_on date,
availability text NOT NULL DEFAULT 'available' CHECK (availability IN ('available','laundry','unavailable')),
archived_at timestamptz,
estimated_prior_wears integer NOT NULL DEFAULT 0 CHECK (estimated_prior_wears >= 0),
tracking_start_date date,
CHECK (estimated_prior_wears = 0 OR tracking_start_date IS NOT NULL),
    UNIQUE (user_id, id)
);
REVOKE ALL ON app.garments FROM PUBLIC, anon, authenticated;
ALTER TABLE app.garments ENABLE ROW LEVEL SECURITY;
ALTER TABLE app.garments FORCE ROW LEVEL SECURITY;
GRANT SELECT, INSERT, UPDATE, DELETE ON app.garments TO service_role;

CREATE POLICY owner_read ON app.garments FOR SELECT TO authenticated
    USING (user_id = (SELECT auth.uid()));
GRANT SELECT ON app.garments TO authenticated;

CREATE TABLE app.garment_images (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id uuid NOT NULL REFERENCES app.profiles(user_id) ON DELETE CASCADE,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    version bigint NOT NULL DEFAULT 1 CHECK (version > 0),
    deleted_at timestamptz,
    garment_id uuid NOT NULL,
variant text NOT NULL CHECK (variant IN ('original','cleaned','thumbnail')),
object_key text NOT NULL UNIQUE CHECK (length(btrim(object_key)) > 0),
status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','ready','failed','deleting')),
content_type text CHECK (content_type IN ('image/jpeg','image/png','image/heic','image/webp')),
byte_count bigint CHECK (byte_count > 0),
UNIQUE (user_id, garment_id, variant),
FOREIGN KEY (user_id, garment_id) REFERENCES app.garments(user_id, id) ON DELETE CASCADE,
    UNIQUE (user_id, id)
);
REVOKE ALL ON app.garment_images FROM PUBLIC, anon, authenticated;
ALTER TABLE app.garment_images ENABLE ROW LEVEL SECURITY;
ALTER TABLE app.garment_images FORCE ROW LEVEL SECURITY;
GRANT SELECT, INSERT, UPDATE, DELETE ON app.garment_images TO service_role;

CREATE POLICY owner_read ON app.garment_images FOR SELECT TO authenticated
    USING (user_id = (SELECT auth.uid()));
GRANT SELECT ON app.garment_images TO authenticated;

CREATE TABLE app.outfits (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id uuid NOT NULL REFERENCES app.profiles(user_id) ON DELETE CASCADE,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    version bigint NOT NULL DEFAULT 1 CHECK (version > 0),
    deleted_at timestamptz,
    name text NOT NULL CHECK (length(btrim(name)) > 0), favorite boolean NOT NULL DEFAULT false,
    UNIQUE (user_id, id)
);
REVOKE ALL ON app.outfits FROM PUBLIC, anon, authenticated;
ALTER TABLE app.outfits ENABLE ROW LEVEL SECURITY;
ALTER TABLE app.outfits FORCE ROW LEVEL SECURITY;
GRANT SELECT, INSERT, UPDATE, DELETE ON app.outfits TO service_role;

CREATE POLICY owner_read ON app.outfits FOR SELECT TO authenticated
    USING (user_id = (SELECT auth.uid()));
GRANT SELECT ON app.outfits TO authenticated;

CREATE TABLE app.outfit_items (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id uuid NOT NULL REFERENCES app.profiles(user_id) ON DELETE CASCADE,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    version bigint NOT NULL DEFAULT 1 CHECK (version > 0),
    deleted_at timestamptz,
    outfit_id uuid NOT NULL, garment_id uuid NOT NULL, position integer NOT NULL CHECK (position >= 0),
UNIQUE (user_id, outfit_id, garment_id), UNIQUE (user_id, outfit_id, position),
FOREIGN KEY (user_id, outfit_id) REFERENCES app.outfits(user_id,id) ON DELETE CASCADE,
FOREIGN KEY (user_id, garment_id) REFERENCES app.garments(user_id,id) ON DELETE CASCADE,
    UNIQUE (user_id, id)
);
REVOKE ALL ON app.outfit_items FROM PUBLIC, anon, authenticated;
ALTER TABLE app.outfit_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE app.outfit_items FORCE ROW LEVEL SECURITY;
GRANT SELECT, INSERT, UPDATE, DELETE ON app.outfit_items TO service_role;

CREATE POLICY owner_read ON app.outfit_items FOR SELECT TO authenticated
    USING (user_id = (SELECT auth.uid()));
GRANT SELECT ON app.outfit_items TO authenticated;

CREATE TABLE app.wear_events (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id uuid NOT NULL REFERENCES app.profiles(user_id) ON DELETE CASCADE,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    version bigint NOT NULL DEFAULT 1 CHECK (version > 0),
    deleted_at timestamptz,
    worn_on date NOT NULL, timezone text NOT NULL,
client_request_id uuid NOT NULL, source_outfit_id uuid,
UNIQUE (user_id, client_request_id),
FOREIGN KEY (user_id, source_outfit_id) REFERENCES app.outfits(user_id,id) ON DELETE SET NULL (source_outfit_id),
    UNIQUE (user_id, id)
);
REVOKE ALL ON app.wear_events FROM PUBLIC, anon, authenticated;
ALTER TABLE app.wear_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE app.wear_events FORCE ROW LEVEL SECURITY;
GRANT SELECT, INSERT, UPDATE, DELETE ON app.wear_events TO service_role;

CREATE POLICY owner_read ON app.wear_events FOR SELECT TO authenticated
    USING (user_id = (SELECT auth.uid()));
GRANT SELECT ON app.wear_events TO authenticated;

CREATE TABLE app.wear_event_items (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id uuid NOT NULL REFERENCES app.profiles(user_id) ON DELETE CASCADE,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    version bigint NOT NULL DEFAULT 1 CHECK (version > 0),
    deleted_at timestamptz,
    wear_event_id uuid NOT NULL, garment_id uuid NOT NULL,
UNIQUE (user_id, wear_event_id, garment_id),
FOREIGN KEY (user_id, wear_event_id) REFERENCES app.wear_events(user_id,id) ON DELETE CASCADE,
FOREIGN KEY (user_id, garment_id) REFERENCES app.garments(user_id,id) ON DELETE CASCADE,
    UNIQUE (user_id, id)
);
REVOKE ALL ON app.wear_event_items FROM PUBLIC, anon, authenticated;
ALTER TABLE app.wear_event_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE app.wear_event_items FORCE ROW LEVEL SECURITY;
GRANT SELECT, INSERT, UPDATE, DELETE ON app.wear_event_items TO service_role;

CREATE POLICY owner_read ON app.wear_event_items FOR SELECT TO authenticated
    USING (user_id = (SELECT auth.uid()));
GRANT SELECT ON app.wear_event_items TO authenticated;

CREATE TABLE app.preferences (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id uuid NOT NULL REFERENCES app.profiles(user_id) ON DELETE CASCADE,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    version bigint NOT NULL DEFAULT 1 CHECK (version > 0),
    deleted_at timestamptz,
    styles text[] NOT NULL DEFAULT '{}', colors text[] NOT NULL DEFAULT '{}',
excluded_categories text[] NOT NULL DEFAULT '{}', notes text,
UNIQUE (user_id),
    UNIQUE (user_id, id)
);
REVOKE ALL ON app.preferences FROM PUBLIC, anon, authenticated;
ALTER TABLE app.preferences ENABLE ROW LEVEL SECURITY;
ALTER TABLE app.preferences FORCE ROW LEVEL SECURITY;
GRANT SELECT, INSERT, UPDATE, DELETE ON app.preferences TO service_role;

CREATE POLICY owner_read ON app.preferences FOR SELECT TO authenticated
    USING (user_id = (SELECT auth.uid()));
GRANT SELECT ON app.preferences TO authenticated;

CREATE TABLE app.outfit_feedback (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id uuid NOT NULL REFERENCES app.profiles(user_id) ON DELETE CASCADE,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    version bigint NOT NULL DEFAULT 1 CHECK (version > 0),
    deleted_at timestamptz,
    outfit_id uuid NOT NULL, rating text NOT NULL CHECK (rating IN ('like','dislike')), reason text,
UNIQUE (user_id, outfit_id),
FOREIGN KEY (user_id, outfit_id) REFERENCES app.outfits(user_id,id) ON DELETE CASCADE,
    UNIQUE (user_id, id)
);
REVOKE ALL ON app.outfit_feedback FROM PUBLIC, anon, authenticated;
ALTER TABLE app.outfit_feedback ENABLE ROW LEVEL SECURITY;
ALTER TABLE app.outfit_feedback FORCE ROW LEVEL SECURITY;
GRANT SELECT, INSERT, UPDATE, DELETE ON app.outfit_feedback TO service_role;

CREATE POLICY owner_read ON app.outfit_feedback FOR SELECT TO authenticated
    USING (user_id = (SELECT auth.uid()));
GRANT SELECT ON app.outfit_feedback TO authenticated;

CREATE TABLE app.ai_jobs (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id uuid NOT NULL REFERENCES app.profiles(user_id) ON DELETE CASCADE,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    version bigint NOT NULL DEFAULT 1 CHECK (version > 0),
    deleted_at timestamptz,
    client_request_id uuid NOT NULL, kind text NOT NULL CHECK (kind IN ('image_analysis','outfit_generation','replacement','trip','purchase_fit')),
status text NOT NULL DEFAULT 'queued' CHECK (status IN ('queued','running','succeeded','failed','cancelled','dead_letter')),
model text, prompt_version text, pricing_version text,
input_tokens bigint CHECK (input_tokens >= 0), output_tokens bigint CHECK (output_tokens >= 0),
cost_microunits bigint CHECK (cost_microunits >= 0), cost_currency text CHECK (cost_currency ~ '^[A-Z]{3}$'),
latency_ms bigint CHECK (latency_ms >= 0),
attempts integer NOT NULL DEFAULT 0 CHECK (attempts >= 0), max_attempts integer NOT NULL DEFAULT 3 CHECK (max_attempts > 0),
available_at timestamptz NOT NULL DEFAULT now(), lease_token uuid, lease_expires_at timestamptz,
error_code text, finished_at timestamptz,
UNIQUE (user_id, client_request_id), CHECK (attempts <= max_attempts),
CHECK ((status = 'running') = (lease_token IS NOT NULL AND lease_expires_at IS NOT NULL)),
CHECK ((lease_token IS NULL) = (lease_expires_at IS NULL)),
    UNIQUE (user_id, id)
);
REVOKE ALL ON app.ai_jobs FROM PUBLIC, anon, authenticated;
ALTER TABLE app.ai_jobs ENABLE ROW LEVEL SECURITY;
ALTER TABLE app.ai_jobs FORCE ROW LEVEL SECURITY;
GRANT SELECT, INSERT, UPDATE, DELETE ON app.ai_jobs TO service_role;

CREATE POLICY owner_read ON app.ai_jobs FOR SELECT TO authenticated
    USING (user_id = (SELECT auth.uid()));
GRANT SELECT ON app.ai_jobs TO authenticated;

CREATE TABLE app.consent_events (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id uuid NOT NULL REFERENCES app.profiles(user_id) ON DELETE CASCADE,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    version bigint NOT NULL DEFAULT 1 CHECK (version > 0),
    deleted_at timestamptz,
    purpose text NOT NULL CHECK (purpose IN ('ai','analytics','notifications','location')),
policy_version text NOT NULL CHECK (length(btrim(policy_version)) > 0),
recipient text, granted boolean NOT NULL, client_request_id uuid NOT NULL,
UNIQUE (user_id, client_request_id),
CHECK (purpose <> 'ai' OR recipient IS NOT NULL),
    UNIQUE (user_id, id)
);
REVOKE ALL ON app.consent_events FROM PUBLIC, anon, authenticated;
ALTER TABLE app.consent_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE app.consent_events FORCE ROW LEVEL SECURITY;
GRANT SELECT, INSERT, UPDATE, DELETE ON app.consent_events TO service_role;

CREATE POLICY owner_read ON app.consent_events FOR SELECT TO authenticated
    USING (user_id = (SELECT auth.uid()));
GRANT SELECT ON app.consent_events TO authenticated;

CREATE TABLE app.planned_outfits (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id uuid NOT NULL REFERENCES app.profiles(user_id) ON DELETE CASCADE,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    version bigint NOT NULL DEFAULT 1 CHECK (version > 0),
    deleted_at timestamptz,
    outfit_id uuid NOT NULL, planned_on date NOT NULL, notes text,
UNIQUE (user_id, outfit_id, planned_on),
FOREIGN KEY (user_id, outfit_id) REFERENCES app.outfits(user_id,id) ON DELETE CASCADE,
    UNIQUE (user_id, id)
);
REVOKE ALL ON app.planned_outfits FROM PUBLIC, anon, authenticated;
ALTER TABLE app.planned_outfits ENABLE ROW LEVEL SECURITY;
ALTER TABLE app.planned_outfits FORCE ROW LEVEL SECURITY;
GRANT SELECT, INSERT, UPDATE, DELETE ON app.planned_outfits TO service_role;

CREATE POLICY owner_read ON app.planned_outfits FOR SELECT TO authenticated
    USING (user_id = (SELECT auth.uid()));
GRANT SELECT ON app.planned_outfits TO authenticated;

CREATE TABLE app.trips (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id uuid NOT NULL REFERENCES app.profiles(user_id) ON DELETE CASCADE,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    version bigint NOT NULL DEFAULT 1 CHECK (version > 0),
    deleted_at timestamptz,
    destination text NOT NULL, starts_on date NOT NULL, ends_on date NOT NULL,
occasions text[] NOT NULL DEFAULT '{}', CHECK (ends_on >= starts_on),
    UNIQUE (user_id, id)
);
REVOKE ALL ON app.trips FROM PUBLIC, anon, authenticated;
ALTER TABLE app.trips ENABLE ROW LEVEL SECURITY;
ALTER TABLE app.trips FORCE ROW LEVEL SECURITY;
GRANT SELECT, INSERT, UPDATE, DELETE ON app.trips TO service_role;

CREATE POLICY owner_read ON app.trips FOR SELECT TO authenticated
    USING (user_id = (SELECT auth.uid()));
GRANT SELECT ON app.trips TO authenticated;

CREATE TABLE app.trip_items (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id uuid NOT NULL REFERENCES app.profiles(user_id) ON DELETE CASCADE,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    version bigint NOT NULL DEFAULT 1 CHECK (version > 0),
    deleted_at timestamptz,
    trip_id uuid NOT NULL, garment_id uuid NOT NULL, packed boolean NOT NULL DEFAULT false,
UNIQUE (user_id, trip_id, garment_id),
FOREIGN KEY (user_id, trip_id) REFERENCES app.trips(user_id,id) ON DELETE CASCADE,
FOREIGN KEY (user_id, garment_id) REFERENCES app.garments(user_id,id) ON DELETE CASCADE,
    UNIQUE (user_id, id)
);
REVOKE ALL ON app.trip_items FROM PUBLIC, anon, authenticated;
ALTER TABLE app.trip_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE app.trip_items FORCE ROW LEVEL SECURITY;
GRANT SELECT, INSERT, UPDATE, DELETE ON app.trip_items TO service_role;

CREATE POLICY owner_read ON app.trip_items FOR SELECT TO authenticated
    USING (user_id = (SELECT auth.uid()));
GRANT SELECT ON app.trip_items TO authenticated;

CREATE TABLE app.purchase_candidates (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id uuid NOT NULL REFERENCES app.profiles(user_id) ON DELETE CASCADE,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    version bigint NOT NULL DEFAULT 1 CHECK (version > 0),
    deleted_at timestamptz,
    name text, object_key text UNIQUE, expires_at timestamptz NOT NULL,
status text NOT NULL DEFAULT 'considering' CHECK (status IN ('considering','purchased','discarded')),
purchased_garment_id uuid,
FOREIGN KEY (user_id, purchased_garment_id) REFERENCES app.garments(user_id,id) ON DELETE SET NULL (purchased_garment_id),
CHECK (purchased_garment_id IS NULL OR status = 'purchased'),
    UNIQUE (user_id, id)
);
REVOKE ALL ON app.purchase_candidates FROM PUBLIC, anon, authenticated;
ALTER TABLE app.purchase_candidates ENABLE ROW LEVEL SECURITY;
ALTER TABLE app.purchase_candidates FORCE ROW LEVEL SECURITY;
GRANT SELECT, INSERT, UPDATE, DELETE ON app.purchase_candidates TO service_role;

CREATE POLICY owner_read ON app.purchase_candidates FOR SELECT TO authenticated
    USING (user_id = (SELECT auth.uid()));
GRANT SELECT ON app.purchase_candidates TO authenticated;

CREATE TABLE app.subscription_entitlements (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id uuid NOT NULL REFERENCES app.profiles(user_id) ON DELETE CASCADE,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    version bigint NOT NULL DEFAULT 1 CHECK (version > 0),
    deleted_at timestamptz,
    original_transaction_id text NOT NULL UNIQUE, product_id text NOT NULL,
status text NOT NULL CHECK (status IN ('active','expired','grace_period','billing_retry','revoked','pending')),
expires_at timestamptz, verified_at timestamptz NOT NULL, environment text NOT NULL CHECK (environment IN ('sandbox','production')),
    UNIQUE (user_id, id)
);
REVOKE ALL ON app.subscription_entitlements FROM PUBLIC, anon, authenticated;
ALTER TABLE app.subscription_entitlements ENABLE ROW LEVEL SECURITY;
ALTER TABLE app.subscription_entitlements FORCE ROW LEVEL SECURITY;
GRANT SELECT, INSERT, UPDATE, DELETE ON app.subscription_entitlements TO service_role;

CREATE POLICY owner_read ON app.subscription_entitlements FOR SELECT TO authenticated
    USING (user_id = (SELECT auth.uid()));
GRANT SELECT ON app.subscription_entitlements TO authenticated;

CREATE TABLE app.subscription_events (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id uuid NOT NULL REFERENCES app.profiles(user_id) ON DELETE CASCADE,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    version bigint NOT NULL DEFAULT 1 CHECK (version > 0),
    deleted_at timestamptz,
    notification_id uuid NOT NULL UNIQUE, entitlement_id uuid NOT NULL,
event_type text NOT NULL, occurred_at timestamptz NOT NULL,
FOREIGN KEY (user_id, entitlement_id) REFERENCES app.subscription_entitlements(user_id,id) ON DELETE CASCADE,
    UNIQUE (user_id, id)
);
REVOKE ALL ON app.subscription_events FROM PUBLIC, anon, authenticated;
ALTER TABLE app.subscription_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE app.subscription_events FORCE ROW LEVEL SECURITY;
GRANT SELECT, INSERT, UPDATE, DELETE ON app.subscription_events TO service_role;

CREATE POLICY owner_read ON app.subscription_events FOR SELECT TO authenticated
    USING (user_id = (SELECT auth.uid()));
GRANT SELECT ON app.subscription_events TO authenticated;

CREATE TABLE app.usage_reservations (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id uuid NOT NULL REFERENCES app.profiles(user_id) ON DELETE CASCADE,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    version bigint NOT NULL DEFAULT 1 CHECK (version > 0),
    deleted_at timestamptz,
    ai_job_id uuid NOT NULL, client_request_id uuid NOT NULL,
units integer NOT NULL CHECK (units > 0),
status text NOT NULL DEFAULT 'reserved' CHECK (status IN ('reserved','settled','released')),
expires_at timestamptz NOT NULL,
UNIQUE (user_id, client_request_id), UNIQUE (user_id, ai_job_id),
FOREIGN KEY (user_id, ai_job_id) REFERENCES app.ai_jobs(user_id,id) ON DELETE CASCADE,
    UNIQUE (user_id, id)
);
REVOKE ALL ON app.usage_reservations FROM PUBLIC, anon, authenticated;
ALTER TABLE app.usage_reservations ENABLE ROW LEVEL SECURITY;
ALTER TABLE app.usage_reservations FORCE ROW LEVEL SECURITY;
GRANT SELECT, INSERT, UPDATE, DELETE ON app.usage_reservations TO service_role;

CREATE POLICY owner_read ON app.usage_reservations FOR SELECT TO authenticated
    USING (user_id = (SELECT auth.uid()));
GRANT SELECT ON app.usage_reservations TO authenticated;

CREATE TABLE app.sync_operations (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id uuid NOT NULL REFERENCES app.profiles(user_id) ON DELETE CASCADE,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    version bigint NOT NULL DEFAULT 1 CHECK (version > 0),
    deleted_at timestamptz,
    client_request_id uuid NOT NULL, entity_type text NOT NULL, entity_id uuid NOT NULL,
base_version bigint CHECK (base_version > 0),
status text NOT NULL CHECK (status IN ('pending','applied','conflict','rejected')),
result_version bigint CHECK (result_version > 0), error_code text,
UNIQUE (user_id, client_request_id),
    UNIQUE (user_id, id)
);
REVOKE ALL ON app.sync_operations FROM PUBLIC, anon, authenticated;
ALTER TABLE app.sync_operations ENABLE ROW LEVEL SECURITY;
ALTER TABLE app.sync_operations FORCE ROW LEVEL SECURITY;
GRANT SELECT, INSERT, UPDATE, DELETE ON app.sync_operations TO service_role;

CREATE POLICY owner_read ON app.sync_operations FOR SELECT TO authenticated
    USING (user_id = (SELECT auth.uid()));
GRANT SELECT ON app.sync_operations TO authenticated;

CREATE TABLE app.deletion_jobs (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id uuid NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    version bigint NOT NULL DEFAULT 1 CHECK (version > 0),
    deleted_at timestamptz,
    client_request_id uuid NOT NULL,
status text NOT NULL DEFAULT 'queued' CHECK (status IN ('queued','running','succeeded','failed','dead_letter')),
attempts integer NOT NULL DEFAULT 0 CHECK (attempts >= 0),
lease_token uuid, lease_expires_at timestamptz, finished_at timestamptz, error_code text,
UNIQUE (user_id, client_request_id),
CHECK ((status = 'running') = (lease_token IS NOT NULL AND lease_expires_at IS NOT NULL)),
CHECK ((lease_token IS NULL) = (lease_expires_at IS NULL)),
    UNIQUE (user_id, id)
);
REVOKE ALL ON app.deletion_jobs FROM PUBLIC, anon, authenticated;
ALTER TABLE app.deletion_jobs ENABLE ROW LEVEL SECURITY;
ALTER TABLE app.deletion_jobs FORCE ROW LEVEL SECURITY;
GRANT SELECT, INSERT, UPDATE, DELETE ON app.deletion_jobs TO service_role;

CREATE POLICY owner_read ON app.deletion_jobs FOR SELECT TO authenticated
    USING (user_id = (SELECT auth.uid()));
GRANT SELECT ON app.deletion_jobs TO authenticated;

CREATE TABLE app.support_requests (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id uuid NOT NULL REFERENCES app.profiles(user_id) ON DELETE CASCADE,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    version bigint NOT NULL DEFAULT 1 CHECK (version > 0),
    deleted_at timestamptz,
    client_request_id uuid NOT NULL, subject text NOT NULL, message text NOT NULL,
status text NOT NULL DEFAULT 'open' CHECK (status IN ('open','in_progress','closed')),
UNIQUE (user_id, client_request_id),
    UNIQUE (user_id, id)
);
REVOKE ALL ON app.support_requests FROM PUBLIC, anon, authenticated;
ALTER TABLE app.support_requests ENABLE ROW LEVEL SECURITY;
ALTER TABLE app.support_requests FORCE ROW LEVEL SECURITY;
GRANT SELECT, INSERT, UPDATE, DELETE ON app.support_requests TO service_role;

CREATE POLICY owner_read ON app.support_requests FOR SELECT TO authenticated
    USING (user_id = (SELECT auth.uid()));
GRANT SELECT ON app.support_requests TO authenticated;

CREATE TABLE app.operator_audit (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id uuid NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    version bigint NOT NULL DEFAULT 1 CHECK (version > 0),
    deleted_at timestamptz,
    operator_id uuid NOT NULL, action text NOT NULL, target_type text NOT NULL,
target_id uuid, request_id uuid NOT NULL, outcome text NOT NULL CHECK (outcome IN ('allowed','denied','failed')),
    UNIQUE (user_id, id)
);
REVOKE ALL ON app.operator_audit FROM PUBLIC, anon, authenticated;
ALTER TABLE app.operator_audit ENABLE ROW LEVEL SECURITY;
ALTER TABLE app.operator_audit FORCE ROW LEVEL SECURITY;
GRANT SELECT, INSERT, UPDATE, DELETE ON app.operator_audit TO service_role;

-- Immutable identity and monotonic revision are not a replacement for the
-- API's UPDATE ... WHERE version = base_version compare-and-swap.
CREATE FUNCTION app.touch_record() RETURNS trigger LANGUAGE plpgsql
SET search_path = pg_catalog AS $$
BEGIN
    IF NEW.id IS DISTINCT FROM OLD.id OR NEW.user_id IS DISTINCT FROM OLD.user_id THEN
        RAISE EXCEPTION 'record identity is immutable' USING ERRCODE = '23514';
    END IF;
    IF OLD.deleted_at IS NOT NULL AND NEW IS DISTINCT FROM OLD
       -- FK cleanup may clear a deleted parent's optional reference, even on
       -- a tombstone. It cannot revive the record or change any other data.
       AND NOT (pg_trigger_depth() > 1 AND (
           (TG_TABLE_NAME = 'wear_events'
            AND to_jsonb(NEW)->'source_outfit_id' = 'null'::jsonb
            AND to_jsonb(NEW) - 'source_outfit_id' = to_jsonb(OLD) - 'source_outfit_id')
           OR (TG_TABLE_NAME = 'purchase_candidates'
            AND to_jsonb(NEW)->'purchased_garment_id' = 'null'::jsonb
            AND to_jsonb(NEW) - 'purchased_garment_id' = to_jsonb(OLD) - 'purchased_garment_id')
       )) THEN
        RAISE EXCEPTION 'tombstone cannot be edited' USING ERRCODE = '23514';
    END IF;
    NEW.created_at := OLD.created_at;
    NEW.updated_at := clock_timestamp();
    NEW.version := OLD.version + 1;
    RETURN NEW;
END;
$$;

CREATE FUNCTION app.validate_wear_day() RETURNS trigger LANGUAGE plpgsql
SET search_path = pg_catalog AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_timezone_names WHERE name = NEW.timezone) THEN
        RAISE EXCEPTION 'unknown timezone' USING ERRCODE = '23514';
    END IF;
    IF NEW.worn_on > (CURRENT_TIMESTAMP AT TIME ZONE NEW.timezone)::date THEN
        RAISE EXCEPTION 'future wear must be a plan' USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER validate_wear_day BEFORE INSERT OR UPDATE ON app.wear_events
FOR EACH ROW EXECUTE FUNCTION app.validate_wear_day();

-- Append-only evidence; deletion by account cleanup remains possible.
CREATE FUNCTION app.reject_evidence_update() RETURNS trigger LANGUAGE plpgsql
SET search_path = pg_catalog AS $$
BEGIN
    RAISE EXCEPTION 'evidence is append-only' USING ERRCODE = '23514';
END;
$$;

CREATE TRIGGER touch_record BEFORE UPDATE ON app.profiles
FOR EACH ROW EXECUTE FUNCTION app.touch_record();

CREATE INDEX profiles_changes ON app.profiles (user_id, updated_at, id);

CREATE TRIGGER touch_record BEFORE UPDATE ON app.garments
FOR EACH ROW EXECUTE FUNCTION app.touch_record();

CREATE INDEX garments_changes ON app.garments (user_id, updated_at, id);

CREATE TRIGGER touch_record BEFORE UPDATE ON app.garment_images
FOR EACH ROW EXECUTE FUNCTION app.touch_record();

CREATE INDEX garment_images_changes ON app.garment_images (user_id, updated_at, id);

CREATE TRIGGER touch_record BEFORE UPDATE ON app.outfits
FOR EACH ROW EXECUTE FUNCTION app.touch_record();

CREATE INDEX outfits_changes ON app.outfits (user_id, updated_at, id);

CREATE TRIGGER touch_record BEFORE UPDATE ON app.outfit_items
FOR EACH ROW EXECUTE FUNCTION app.touch_record();

CREATE INDEX outfit_items_changes ON app.outfit_items (user_id, updated_at, id);

CREATE TRIGGER touch_record BEFORE UPDATE ON app.wear_events
FOR EACH ROW EXECUTE FUNCTION app.touch_record();

CREATE INDEX wear_events_changes ON app.wear_events (user_id, updated_at, id);

CREATE TRIGGER touch_record BEFORE UPDATE ON app.wear_event_items
FOR EACH ROW EXECUTE FUNCTION app.touch_record();

CREATE INDEX wear_event_items_changes ON app.wear_event_items (user_id, updated_at, id);

CREATE TRIGGER touch_record BEFORE UPDATE ON app.preferences
FOR EACH ROW EXECUTE FUNCTION app.touch_record();

CREATE INDEX preferences_changes ON app.preferences (user_id, updated_at, id);

CREATE TRIGGER touch_record BEFORE UPDATE ON app.outfit_feedback
FOR EACH ROW EXECUTE FUNCTION app.touch_record();

CREATE INDEX outfit_feedback_changes ON app.outfit_feedback (user_id, updated_at, id);

CREATE TRIGGER touch_record BEFORE UPDATE ON app.ai_jobs
FOR EACH ROW EXECUTE FUNCTION app.touch_record();

CREATE INDEX ai_jobs_changes ON app.ai_jobs (user_id, updated_at, id);

CREATE TRIGGER touch_record BEFORE UPDATE ON app.consent_events
FOR EACH ROW EXECUTE FUNCTION app.touch_record();

CREATE TRIGGER immutable_evidence BEFORE UPDATE ON app.consent_events
FOR EACH ROW EXECUTE FUNCTION app.reject_evidence_update();

CREATE INDEX consent_events_changes ON app.consent_events (user_id, updated_at, id);

CREATE TRIGGER touch_record BEFORE UPDATE ON app.planned_outfits
FOR EACH ROW EXECUTE FUNCTION app.touch_record();

CREATE INDEX planned_outfits_changes ON app.planned_outfits (user_id, updated_at, id);

CREATE TRIGGER touch_record BEFORE UPDATE ON app.trips
FOR EACH ROW EXECUTE FUNCTION app.touch_record();

CREATE INDEX trips_changes ON app.trips (user_id, updated_at, id);

CREATE TRIGGER touch_record BEFORE UPDATE ON app.trip_items
FOR EACH ROW EXECUTE FUNCTION app.touch_record();

CREATE INDEX trip_items_changes ON app.trip_items (user_id, updated_at, id);

CREATE TRIGGER touch_record BEFORE UPDATE ON app.purchase_candidates
FOR EACH ROW EXECUTE FUNCTION app.touch_record();

CREATE INDEX purchase_candidates_changes ON app.purchase_candidates (user_id, updated_at, id);

CREATE TRIGGER touch_record BEFORE UPDATE ON app.subscription_entitlements
FOR EACH ROW EXECUTE FUNCTION app.touch_record();

CREATE INDEX subscription_entitlements_changes ON app.subscription_entitlements (user_id, updated_at, id);

CREATE TRIGGER touch_record BEFORE UPDATE ON app.subscription_events
FOR EACH ROW EXECUTE FUNCTION app.touch_record();

CREATE TRIGGER immutable_evidence BEFORE UPDATE ON app.subscription_events
FOR EACH ROW EXECUTE FUNCTION app.reject_evidence_update();

CREATE INDEX subscription_events_changes ON app.subscription_events (user_id, updated_at, id);

CREATE TRIGGER touch_record BEFORE UPDATE ON app.usage_reservations
FOR EACH ROW EXECUTE FUNCTION app.touch_record();

CREATE INDEX usage_reservations_changes ON app.usage_reservations (user_id, updated_at, id);

CREATE TRIGGER touch_record BEFORE UPDATE ON app.sync_operations
FOR EACH ROW EXECUTE FUNCTION app.touch_record();

CREATE INDEX sync_operations_changes ON app.sync_operations (user_id, updated_at, id);

CREATE TRIGGER touch_record BEFORE UPDATE ON app.deletion_jobs
FOR EACH ROW EXECUTE FUNCTION app.touch_record();

CREATE INDEX deletion_jobs_changes ON app.deletion_jobs (user_id, updated_at, id);

CREATE TRIGGER touch_record BEFORE UPDATE ON app.support_requests
FOR EACH ROW EXECUTE FUNCTION app.touch_record();

CREATE INDEX support_requests_changes ON app.support_requests (user_id, updated_at, id);

CREATE TRIGGER touch_record BEFORE UPDATE ON app.operator_audit
FOR EACH ROW EXECUTE FUNCTION app.touch_record();

CREATE TRIGGER immutable_evidence BEFORE UPDATE ON app.operator_audit
FOR EACH ROW EXECUTE FUNCTION app.reject_evidence_update();

CREATE INDEX garments_browse ON app.garments (user_id, category, availability) WHERE deleted_at IS NULL AND archived_at IS NULL;
CREATE INDEX wear_events_days ON app.wear_events (user_id, worn_on) WHERE deleted_at IS NULL;
CREATE INDEX wear_items_garment ON app.wear_event_items (user_id, garment_id, wear_event_id);
CREATE INDEX outfit_items_garment ON app.outfit_items (user_id, garment_id);
CREATE INDEX trip_items_garment ON app.trip_items (user_id, garment_id);
CREATE INDEX wear_source ON app.wear_events (user_id, source_outfit_id);
CREATE INDEX planned_outfits_calendar ON app.planned_outfits (user_id, planned_on);
CREATE INDEX subscription_events_parent ON app.subscription_events (user_id, entitlement_id);
CREATE INDEX purchase_candidates_garment ON app.purchase_candidates (user_id, purchased_garment_id);
CREATE INDEX ai_jobs_queue ON app.ai_jobs (available_at, id) WHERE status = 'queued';
CREATE INDEX ai_jobs_lease ON app.ai_jobs (lease_expires_at) WHERE status = 'running';
CREATE INDEX deletion_jobs_queue ON app.deletion_jobs (status, created_at);
CREATE INDEX consent_latest ON app.consent_events (user_id, purpose, created_at DESC, id);
CREATE INDEX reservations_expiry ON app.usage_reservations (expires_at) WHERE status = 'reserved';
CREATE INDEX candidates_expiry ON app.purchase_candidates (expires_at);
CREATE INDEX audit_target ON app.operator_audit (user_id, created_at);
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA app FROM PUBLIC;
