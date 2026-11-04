-- Fail closed until an operator installs an approved pricing envelope and limits.
-- Budget is cumulative in one configured currency, never reset automatically.
CREATE TABLE api_private.ai_cost_policy (
    singleton boolean PRIMARY KEY DEFAULT true CHECK (singleton),
    enabled boolean NOT NULL DEFAULT false,
    monthly_user_units integer NOT NULL CHECK (monthly_user_units > 0),
    budget_microunits bigint NOT NULL CHECK (budget_microunits >= 0),
    committed_microunits bigint NOT NULL DEFAULT 0 CHECK (committed_microunits >= 0),
    currency text NOT NULL CHECK (currency ~ '^[A-Z]{3}$'),
    pricing_version text NOT NULL CHECK (length(btrim(pricing_version)) > 0),
    -- Upper bound for ONE request, including maximum input/output and image cost.
    request_cap_microunits bigint NOT NULL CHECK (request_cap_microunits > 0)
);
CREATE TABLE api_private.ai_cost_holds (
    reservation_id uuid PRIMARY KEY REFERENCES app.usage_reservations(id) ON DELETE CASCADE,
    amount bigint NOT NULL CHECK (amount > 0),
    pricing_version text NOT NULL,
    currency text NOT NULL,
    dispatched boolean NOT NULL DEFAULT false,
    refunded boolean NOT NULL DEFAULT false
);
REVOKE ALL ON api_private.ai_cost_policy, api_private.ai_cost_holds FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION api_private.guard_ai_reservation() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
DECLARE p api_private.ai_cost_policy%ROWTYPE; used bigint; cap bigint; attempts integer;
BEGIN
    -- One row serializes admission across ALL owners. No read/check/write race.
    SELECT * INTO p FROM api_private.ai_cost_policy WHERE singleton FOR UPDATE;
    IF NOT FOUND OR NOT p.enabled THEN RAISE EXCEPTION 'ai_disabled' USING ERRCODE = '22023'; END IF;
    SELECT max_attempts INTO attempts FROM app.ai_jobs WHERE id = NEW.ai_job_id;
    IF attempts NOT BETWEEN 1 AND 3 THEN RAISE EXCEPTION 'ai_retry_limit' USING ERRCODE = '22023'; END IF;
    SELECT coalesce(sum(units),0) INTO used FROM app.usage_reservations
        WHERE user_id = NEW.user_id AND status IN ('reserved','settled')
        AND (created_at >= date_trunc('month',clock_timestamp() AT TIME ZONE 'UTC') AT TIME ZONE 'UTC'
             OR status = 'reserved');
    IF used + NEW.units > p.monthly_user_units THEN RAISE EXCEPTION 'ai_quota_exceeded' USING ERRCODE = '22023'; END IF;
    -- Include every possible lease recovery and the one permitted JSON repair.
    cap := p.request_cap_microunits * attempts * 2;
    IF cap > p.budget_microunits - p.committed_microunits THEN
        RAISE EXCEPTION 'ai_budget_exceeded' USING ERRCODE = '22023';
    END IF;
    UPDATE api_private.ai_cost_policy SET committed_microunits = committed_microunits + cap WHERE singleton;
    INSERT INTO api_private.ai_cost_holds(reservation_id,amount,pricing_version,currency)
        VALUES(NEW.id,cap,p.pricing_version,p.currency);
    RETURN NEW;
END $$;
-- AFTER INSERT allows the hold FK; an exception rolls back the whole enqueue.
CREATE TRIGGER ai_reservation_admission AFTER INSERT ON app.usage_reservations
    FOR EACH ROW EXECUTE FUNCTION api_private.guard_ai_reservation();

CREATE FUNCTION api_private.release_ai_cost() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
DECLARE refund bigint;
BEGIN
    IF TG_OP = 'DELETE' OR NEW.status = 'released' THEN
        UPDATE api_private.ai_cost_holds SET refunded = true
            WHERE reservation_id = OLD.id AND NOT dispatched AND NOT refunded RETURNING amount INTO refund;
        IF refund IS NOT NULL THEN
            UPDATE api_private.ai_cost_policy SET committed_microunits = committed_microunits - refund WHERE singleton;
        END IF;
    END IF;
    IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER ai_cost_release BEFORE UPDATE OF status OR DELETE ON app.usage_reservations
    FOR EACH ROW EXECUTE FUNCTION api_private.release_ai_cost();

-- Preserve the existing consent and lease fence; its internal entry point is private.
ALTER FUNCTION app.jobs_authorize_dispatch(uuid,uuid) RENAME TO jobs_authorize_dispatch_consent;
REVOKE ALL ON FUNCTION app.jobs_authorize_dispatch_consent(uuid,uuid) FROM PUBLIC, anon, authenticated, service_role;
CREATE FUNCTION app.jobs_authorize_dispatch(job_id uuid, token uuid) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
DECLARE allowed boolean;
BEGIN
    IF NOT app.jobs_authorize_dispatch_consent(job_id,token) THEN RETURN false; END IF;
    -- Lock order follows reservation transitions (hold then policy).
    PERFORM 1 FROM api_private.ai_cost_holds h JOIN app.usage_reservations r ON r.id = h.reservation_id
        WHERE r.ai_job_id = job_id AND r.status = 'reserved' AND NOT h.refunded FOR UPDATE OF h;
    allowed := FOUND;
    PERFORM 1 FROM api_private.ai_cost_policy WHERE singleton AND enabled FOR SHARE;
    IF NOT FOUND OR NOT allowed THEN
        PERFORM app.jobs_finish(job_id,token,'permanent');
        RETURN false;
    END IF;
    UPDATE api_private.ai_cost_holds h SET dispatched = true
        FROM app.usage_reservations r WHERE r.id = h.reservation_id AND r.ai_job_id = job_id;
    RETURN true;
END $$;
REVOKE ALL ON FUNCTION api_private.guard_ai_reservation(), api_private.release_ai_cost(),
    app.jobs_authorize_dispatch(uuid,uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION app.jobs_authorize_dispatch(uuid,uuid) TO service_role;

-- Existing jobs have no priced hold: authorization refuses them safely. Prevent
-- a later retry-policy increase from exceeding the envelope reserved at admission.
CREATE FUNCTION api_private.guard_ai_attempts() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog AS $$
BEGIN
    IF NEW.max_attempts > 3 OR (TG_OP = 'UPDATE' AND NEW.max_attempts > OLD.max_attempts) THEN
        RAISE EXCEPTION 'ai_retry_limit' USING ERRCODE = '22023';
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER ai_retry_limit BEFORE INSERT OR UPDATE OF max_attempts ON app.ai_jobs
    FOR EACH ROW EXECUTE FUNCTION api_private.guard_ai_attempts();
REVOKE ALL ON FUNCTION api_private.guard_ai_attempts() FROM PUBLIC, anon, authenticated;
