-- Run as the schema owner after 027. This creates no login or operator identity.
DO $$ BEGIN
 IF NOT EXISTS(SELECT FROM pg_roles WHERE rolname='szafa_ops') THEN
  CREATE ROLE szafa_ops NOLOGIN NOINHERIT NOSUPERUSER NOBYPASSRLS;
 END IF;
 IF EXISTS(SELECT FROM pg_roles WHERE rolname='szafa_ops' AND (rolcanlogin OR rolsuper OR rolbypassrls OR rolinherit)) THEN
  RAISE EXCEPTION 'Unsafe existing szafa_ops role';
 END IF;
END $$;
GRANT USAGE ON SCHEMA ops_private TO szafa_ops;
GRANT EXECUTE ON FUNCTION ops_private.command(text,text,uuid,jsonb) TO szafa_ops;
-- Provision a separate NOINHERIT LOGIN member of szafa_ops using the secret
-- channel. Never reuse the consumer gateway login, owner or service_role.
