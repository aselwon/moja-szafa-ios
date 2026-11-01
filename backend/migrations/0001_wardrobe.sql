-- T008 v1: wardrobe and immutable wear snapshots. PostgreSQL 15+.
-- Supabase supplies auth.users, auth.uid(), authenticated and service_role.
BEGIN;
CREATE SCHEMA app;
REVOKE ALL ON SCHEMA app FROM PUBLIC;
CREATE TABLE app.schema_migrations (
    version integer PRIMARY KEY,
    applied_at timestamptz NOT NULL DEFAULT now()
);
REVOKE ALL ON app.schema_migrations FROM PUBLIC, authenticated, service_role;
CREATE TABLE app.profiles (
    id uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    version bigint NOT NULL DEFAULT 1 CHECK (version > 0),
    display_name text,
    language text NOT NULL DEFAULT 'pl' CHECK (language IN ('pl', 'en')),
    city text,
    deleted_at timestamptz
);

-- Every update advances the version; clients cannot assign their own version.
-- Optimistic base_version matching and atomic multirow mutations belong to T009.
CREATE FUNCTION app.touch_record() RETURNS trigger LANGUAGE plpgsql
SET search_path = pg_catalog AS $$
BEGIN
    IF NEW.id IS DISTINCT FROM OLD.id THEN
        RAISE EXCEPTION 'immutable id' USING ERRCODE = '23514';
    END IF;
    IF to_jsonb(NEW)->'user_id' IS DISTINCT FROM to_jsonb(OLD)->'user_id' THEN
        RAISE EXCEPTION 'immutable owner' USING ERRCODE = '23514';
    END IF;
    NEW.created_at := OLD.created_at;
    NEW.updated_at := clock_timestamp();
    NEW.version := OLD.version + 1;
    RETURN NEW;
END;
$$;

CREATE TABLE app.garments (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id uuid NOT NULL REFERENCES app.profiles(id) ON DELETE CASCADE,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    version bigint NOT NULL DEFAULT 1 CHECK (version > 0),
    category text NOT NULL CHECK (category IN ('top','bottom','shoes','dress','jumpsuit','outerwear','accessory')),
    subcategory text,
    name text NOT NULL CHECK (length(btrim(name)) > 0),
    colors text[] NOT NULL DEFAULT '{}',
    pattern text,
    seasons text[] NOT NULL DEFAULT '{}' CHECK (seasons <@ ARRAY['spring','summer','autumn','winter']),
    formality smallint CHECK (formality BETWEEN 1 AND 5),
    price_grosz bigint CHECK (price_grosz >= 0),
    currency text NOT NULL DEFAULT 'PLN' CHECK (currency = 'PLN'),
    brand text,
    purchased_on date,
    availability text NOT NULL DEFAULT 'available' CHECK (availability IN ('available','laundry','unavailable')),
    archived_at timestamptz,
    deleted_at timestamptz,
    estimated_prior_wears integer NOT NULL DEFAULT 0 CHECK (estimated_prior_wears >= 0),
    tracking_start_date date,
    CHECK (estimated_prior_wears = 0 OR tracking_start_date IS NOT NULL),
    UNIQUE (user_id, id)
);

CREATE TABLE app.garment_images (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id uuid NOT NULL REFERENCES app.profiles(id) ON DELETE CASCADE,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    version bigint NOT NULL DEFAULT 1 CHECK (version > 0),
    garment_id uuid NOT NULL,
    kind text NOT NULL CHECK (kind IN ('original','cleaned','thumbnail')),
    object_key text NOT NULL UNIQUE CHECK (length(btrim(object_key)) > 0),
    state text NOT NULL DEFAULT 'pending' CHECK (state IN ('pending','ready','deleting','failed')),
    mime_type text CHECK (mime_type IN ('image/jpeg','image/png','image/heic','image/webp')),
    byte_count bigint CHECK (byte_count > 0),
    UNIQUE (garment_id, kind),
    UNIQUE (user_id, id),
    FOREIGN KEY (user_id, garment_id) REFERENCES app.garments(user_id, id) ON DELETE CASCADE
);

CREATE TABLE app.outfits (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id uuid NOT NULL REFERENCES app.profiles(id) ON DELETE CASCADE,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    version bigint NOT NULL DEFAULT 1 CHECK (version > 0),
    name text NOT NULL CHECK (length(btrim(name)) > 0),
    is_favorite boolean NOT NULL DEFAULT false,
    deleted_at timestamptz,
    UNIQUE (user_id, id)
);

CREATE TABLE app.outfit_items (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id uuid NOT NULL REFERENCES app.profiles(id) ON DELETE CASCADE,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    version bigint NOT NULL DEFAULT 1 CHECK (version > 0),
    outfit_id uuid NOT NULL,
    garment_id uuid NOT NULL,
    position integer NOT NULL CHECK (position >= 0),
    UNIQUE (outfit_id, garment_id),
    UNIQUE (outfit_id, position),
    UNIQUE (user_id, id),
    FOREIGN KEY (user_id, outfit_id) REFERENCES app.outfits(user_id, id) ON DELETE CASCADE,
    FOREIGN KEY (user_id, garment_id) REFERENCES app.garments(user_id, id) ON DELETE CASCADE
);

CREATE TABLE app.wear_events (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id uuid NOT NULL REFERENCES app.profiles(id) ON DELETE CASCADE,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    version bigint NOT NULL DEFAULT 1 CHECK (version > 0),
    worn_on date NOT NULL,
    timezone text NOT NULL,
    client_request_id uuid NOT NULL,
    source_outfit_id uuid,
    deleted_at timestamptz,
    UNIQUE (user_id, client_request_id),
    UNIQUE (user_id, id),
    FOREIGN KEY (user_id, source_outfit_id) REFERENCES app.outfits(user_id, id) ON DELETE SET NULL (source_outfit_id)
);

CREATE TABLE app.wear_event_items (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id uuid NOT NULL REFERENCES app.profiles(id) ON DELETE CASCADE,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    version bigint NOT NULL DEFAULT 1 CHECK (version > 0),
    wear_event_id uuid NOT NULL,
    garment_id uuid NOT NULL,
    UNIQUE (wear_event_id, garment_id),
    UNIQUE (user_id, id),
    FOREIGN KEY (user_id, wear_event_id) REFERENCES app.wear_events(user_id, id) ON DELETE CASCADE,
    FOREIGN KEY (user_id, garment_id) REFERENCES app.garments(user_id, id) ON DELETE CASCADE
);

-- Validate against the supplied local timezone, not the database/session timezone.
-- Do not put CURRENT_DATE in a CHECK: its meaning changes after insertion.
CREATE FUNCTION app.validate_wear_date() RETURNS trigger LANGUAGE plpgsql
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
CREATE TRIGGER validate_wear_date BEFORE INSERT OR UPDATE ON app.wear_events
FOR EACH ROW EXECUTE FUNCTION app.validate_wear_date();

CREATE INDEX garments_owner_active ON app.garments (user_id, category, availability) WHERE deleted_at IS NULL AND archived_at IS NULL;
CREATE INDEX garments_owner_changed ON app.garments (user_id, updated_at, id);
CREATE INDEX garment_images_parent ON app.garment_images (user_id, garment_id);
CREATE INDEX outfit_items_garment ON app.outfit_items (user_id, garment_id);
CREATE INDEX wear_events_owner_day ON app.wear_events (user_id, worn_on) WHERE deleted_at IS NULL;
CREATE INDEX wear_items_garment ON app.wear_event_items (user_id, garment_id, wear_event_id);

-- Clients can read their records; all mutations require the trusted API.
-- This avoids partial wear events, self-awarded entitlements and forged consent.
GRANT USAGE ON SCHEMA app TO authenticated, service_role;
DO $$
DECLARE t text;
BEGIN
    FOREACH t IN ARRAY ARRAY['profiles','garments','garment_images','outfits','outfit_items','wear_events','wear_event_items'] LOOP
        EXECUTE format('ALTER TABLE app.%I ENABLE ROW LEVEL SECURITY', t);
        EXECUTE format('ALTER TABLE app.%I FORCE ROW LEVEL SECURITY', t);
        EXECUTE format('REVOKE ALL ON app.%I FROM PUBLIC, authenticated', t);
        EXECUTE format('GRANT SELECT ON app.%I TO authenticated', t);
        EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON app.%I TO service_role', t);
        EXECUTE format('CREATE POLICY owner_read ON app.%I FOR SELECT TO authenticated USING ((SELECT auth.uid()) = %I)', t, CASE WHEN t = 'profiles' THEN 'id' ELSE 'user_id' END);
        EXECUTE format('CREATE TRIGGER touch_record BEFORE UPDATE ON app.%I FOR EACH ROW EXECUTE FUNCTION app.touch_record()', t);
    END LOOP;
END;
$$;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA app FROM PUBLIC;
INSERT INTO app.schema_migrations (version) VALUES (1);
COMMIT;
