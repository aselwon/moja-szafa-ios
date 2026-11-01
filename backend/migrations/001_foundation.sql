-- Requires Supabase Auth (auth.users, auth.uid()) and its standard roles.
-- Test-only equivalents are supplied by tests/bootstrap.sql, never in production.
CREATE SCHEMA app;
REVOKE ALL ON SCHEMA app FROM PUBLIC;
GRANT USAGE ON SCHEMA app TO authenticated, service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA app REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;

CREATE TABLE app.profiles (
    id uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
    user_id uuid NOT NULL UNIQUE REFERENCES auth.users(id) ON DELETE CASCADE,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    version bigint NOT NULL DEFAULT 1 CHECK (version > 0),
    deleted_at timestamptz,
    display_name text,
    language text NOT NULL DEFAULT 'pl' CHECK (language IN ('pl', 'en')),
    city text,
    CHECK (id = user_id),
    UNIQUE (user_id, id)
);
REVOKE ALL ON app.profiles FROM PUBLIC, anon, authenticated;
ALTER TABLE app.profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE app.profiles FORCE ROW LEVEL SECURITY;
CREATE POLICY owner_read ON app.profiles FOR SELECT TO authenticated
    USING (user_id = (SELECT auth.uid()));
GRANT SELECT ON app.profiles TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON app.profiles TO service_role;
