-- Plans are intentions. Only the explicit confirm action writes wear history.
ALTER TABLE app.planned_outfits ADD COLUMN timezone text NOT NULL DEFAULT 'UTC';
ALTER TABLE app.planned_outfits DROP CONSTRAINT planned_outfits_user_id_outfit_id_planned_on_key;
CREATE UNIQUE INDEX planned_outfits_live_day ON app.planned_outfits(user_id,outfit_id,planned_on) WHERE deleted_at IS NULL;
-- Plans have a narrowly reversible deletion for Undo; wear and garment
-- tombstones retain the existing irreversible trigger unchanged.
CREATE FUNCTION api_private.touch_plan() RETURNS trigger LANGUAGE plpgsql
SET search_path = pg_catalog AS $$
BEGIN
    IF NEW.id IS DISTINCT FROM OLD.id OR NEW.user_id IS DISTINCT FROM OLD.user_id THEN
        RAISE EXCEPTION 'record identity is immutable' USING ERRCODE='23514';
    END IF;
    IF OLD.deleted_at IS NOT NULL AND NEW IS DISTINCT FROM OLD
       AND NOT (NEW.deleted_at IS NULL AND to_jsonb(NEW)-'deleted_at'=to_jsonb(OLD)-'deleted_at') THEN
        RAISE EXCEPTION 'deleted plan can only be restored unchanged' USING ERRCODE='23514';
    END IF;
    NEW.created_at := OLD.created_at;
    NEW.updated_at := clock_timestamp();
    NEW.version := OLD.version+1;
    RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION api_private.touch_plan() FROM PUBLIC,anon,authenticated;
DROP TRIGGER touch_record ON app.planned_outfits;
CREATE TRIGGER touch_record BEFORE UPDATE ON app.planned_outfits FOR EACH ROW EXECUTE FUNCTION api_private.touch_plan();

CREATE TABLE api_private.plan_confirmations (
    user_id uuid NOT NULL REFERENCES app.profiles(user_id) ON DELETE CASCADE,
    plan_id uuid NOT NULL,
    planned_on date NOT NULL,
    wear_id uuid NOT NULL,
    PRIMARY KEY(user_id,plan_id,planned_on),
    FOREIGN KEY(user_id,plan_id) REFERENCES app.planned_outfits(user_id,id) ON DELETE CASCADE,
    FOREIGN KEY(user_id,wear_id) REFERENCES app.wear_events(user_id,id) ON DELETE CASCADE
);
REVOKE ALL ON api_private.plan_confirmations FROM PUBLIC,anon,authenticated;

CREATE FUNCTION api_private.plan_item(p app.planned_outfits) RETURNS jsonb
LANGUAGE sql STABLE SET search_path = pg_catalog AS $$
    SELECT jsonb_build_object('id',p.id,'version',p.version,'day',to_char(p.planned_on,'YYYY-MM-DD'),
        'timezone',p.timezone,'deleted',p.deleted_at IS NOT NULL,
        'outfit',api_private.outfit_item(o),
        'wearID',(SELECT c.wear_id FROM api_private.plan_confirmations c
            WHERE c.user_id=p.user_id AND c.plan_id=p.id AND c.planned_on=p.planned_on))
    FROM app.outfits o WHERE o.user_id=p.user_id AND o.id=p.outfit_id;
$$;
REVOKE ALL ON FUNCTION api_private.plan_item(app.planned_outfits) FROM PUBLIC,anon,authenticated;

CREATE FUNCTION app.api_v1_planner(request jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
DECLARE
    owner_id uuid := auth.uid();
    request_id uuid := gen_random_uuid();
    action text := request->>'action';
    operation uuid;
    plan_id uuid;
    outfit_id uuid;
    base bigint;
    day date;
    zone text;
    first_day date;
    last_day date;
    after_id uuid;
    next_cursor uuid;
    plan app.planned_outfits%ROWTYPE;
    previous api_private.mutations%ROWTYPE;
    result jsonb;
    wear uuid;
    garment_ids uuid[];
BEGIN
    IF owner_id IS NULL THEN
        RETURN jsonb_build_object('error',jsonb_build_object('code','unauthorized','message','Sign in required','request_id',request_id));
    END IF;
    PERFORM 1 FROM app.profiles WHERE user_id=owner_id AND deleted_at IS NULL FOR SHARE;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('error',jsonb_build_object('code','account_unavailable','message','Account unavailable','request_id',request_id));
    END IF;
    IF jsonb_typeof(request) IS DISTINCT FROM 'object' OR action IS NULL OR action NOT IN ('list','create','move','delete','restore','confirm')
    THEN RAISE EXCEPTION USING ERRCODE='22023'; END IF;
    IF action='list' THEN
        IF NOT request ?& ARRAY['action','from','through'] OR request-ARRAY['action','from','through','cursor'] <> '{}'
            OR coalesce(request->>'from','') !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
            OR coalesce(request->>'through','') !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
        THEN RAISE EXCEPTION USING ERRCODE='22023'; END IF;
        first_day := (request->>'from')::date; last_day := (request->>'through')::date;
        IF last_day < first_day OR last_day-first_day>366 THEN RAISE EXCEPTION USING ERRCODE='22023'; END IF;
        after_id := (request->>'cursor')::uuid;
        SELECT coalesce(jsonb_agg(api_private.plan_item(p::app.planned_outfits) ORDER BY p.id),'[]') INTO result
            FROM (SELECT * FROM app.planned_outfits p WHERE p.user_id=owner_id AND p.deleted_at IS NULL
                AND p.planned_on BETWEEN first_day AND last_day AND (after_id IS NULL OR p.id>after_id)
                ORDER BY p.id LIMIT 41) p;
        IF jsonb_array_length(result)>40 THEN
            result := result-40;
            next_cursor := (result->39->>'id')::uuid;
        END IF;
        RETURN jsonb_build_object('data',jsonb_build_object('items',result,'nextCursor',next_cursor),'request_id',request_id);
    END IF;
    IF NOT request ?& ARRAY['action','operationID','id','baseVersion']
        OR request-ARRAY['action','operationID','id','baseVersion','outfitID','day','timezone','outfitVersion'] <> '{}'
        OR coalesce(request->>'baseVersion','') !~ '^[0-9]+$'
        OR jsonb_typeof(request->'baseVersion') IS DISTINCT FROM 'number'
    THEN RAISE EXCEPTION USING ERRCODE='22023'; END IF;
    operation := (request->>'operationID')::uuid; plan_id := (request->>'id')::uuid; base := (request->>'baseVersion')::bigint;
    IF operation IS NULL OR plan_id IS NULL THEN RAISE EXCEPTION USING ERRCODE='22023'; END IF;
    IF action IN ('create','move') THEN
        IF NOT request ?& ARRAY['day','timezone'] OR coalesce(request->>'day','') !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
            OR NOT EXISTS(SELECT FROM pg_timezone_names WHERE name=request->>'timezone')
        THEN RAISE EXCEPTION USING ERRCODE='22023'; END IF;
        day := (request->>'day')::date; zone := request->>'timezone';
    ELSIF request ?| ARRAY['day','timezone','outfitID'] THEN RAISE EXCEPTION USING ERRCODE='22023';
    END IF;
    IF action='create' THEN
        outfit_id := (request->>'outfitID')::uuid;
        IF outfit_id IS NULL OR base<>0 THEN RAISE EXCEPTION USING ERRCODE='22023'; END IF;
    ELSIF request ? 'outfitID' OR base<1 THEN RAISE EXCEPTION USING ERRCODE='22023'; END IF;
    IF action='confirm' THEN
        IF jsonb_typeof(request->'outfitVersion') IS DISTINCT FROM 'number' OR coalesce(request->>'outfitVersion','') !~ '^[1-9][0-9]*$'
        THEN RAISE EXCEPTION USING ERRCODE='22023'; END IF;
    ELSIF request ? 'outfitVersion' THEN RAISE EXCEPTION USING ERRCODE='22023'; END IF;
    -- Replay precedes clock-sensitive validation so an accepted future plan can
    -- still be retried after midnight without creating a new intent.
    INSERT INTO api_private.mutations VALUES(owner_id,operation,request,NULL) ON CONFLICT DO NOTHING;
    SELECT * INTO previous FROM api_private.mutations m WHERE m.user_id=owner_id AND m.operation_id=operation FOR UPDATE;
    IF previous.request<>request THEN
        RETURN jsonb_build_object('error',jsonb_build_object('code','idempotency_conflict','message','Operation already used','request_id',request_id));
    END IF;
    IF previous.response IS NOT NULL THEN RETURN previous.response; END IF;
    IF action IN ('create','move') AND (day < (clock_timestamp() AT TIME ZONE zone)::date OR day > (clock_timestamp() AT TIME ZONE zone)::date+366)
    THEN RAISE EXCEPTION USING ERRCODE='22023'; END IF;
    IF action='create' THEN
        PERFORM 1 FROM app.outfits o WHERE o.user_id=owner_id AND o.id=outfit_id AND o.deleted_at IS NULL FOR SHARE;
        IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='22023'; END IF;
        INSERT INTO app.planned_outfits(id,user_id,outfit_id,planned_on,timezone) VALUES(plan_id,owner_id,outfit_id,day,zone) RETURNING * INTO plan;
    ELSE
        SELECT * INTO plan FROM app.planned_outfits p WHERE p.user_id=owner_id AND p.id=plan_id FOR UPDATE;
        IF NOT FOUND OR plan.version<>base OR (action='restore') IS DISTINCT FROM (plan.deleted_at IS NOT NULL)
        THEN RAISE EXCEPTION USING ERRCODE='P0002'; END IF;
        IF action='move' THEN
            UPDATE app.planned_outfits SET planned_on=day,timezone=zone WHERE id=plan_id RETURNING * INTO plan;
        ELSIF action='delete' THEN
            UPDATE app.planned_outfits SET deleted_at=clock_timestamp() WHERE id=plan_id RETURNING * INTO plan;
        ELSIF action='restore' THEN
            UPDATE app.planned_outfits SET deleted_at=NULL WHERE id=plan_id RETURNING * INTO plan;
        ELSIF action='confirm' THEN
            SELECT c.wear_id INTO wear FROM api_private.plan_confirmations c
                WHERE c.user_id=owner_id AND c.plan_id=plan.id AND c.planned_on=plan.planned_on;
            IF wear IS NULL THEN
                -- Outfit edits hold this row while replacing its membership.
                PERFORM 1 FROM app.outfits o WHERE o.user_id=owner_id AND o.id=plan.outfit_id AND o.deleted_at IS NULL AND o.version=(request->>'outfitVersion')::bigint FOR SHARE;
                IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='P0002'; END IF;
                SELECT array_agg(i.garment_id ORDER BY i.garment_id) INTO garment_ids FROM app.outfit_items i
                    WHERE i.user_id=owner_id AND i.outfit_id=plan.outfit_id AND i.deleted_at IS NULL;
                wear := gen_random_uuid();
                result := app.api_v1_save_wear(jsonb_build_object('operationID',gen_random_uuid(),'wear',jsonb_build_object(
                    'id',wear,'version',0,'deleted',false,'wornOn',to_char(plan.planned_on,'YYYY-MM-DD'),
                    'timezone',plan.timezone,'garmentIDs',to_jsonb(garment_ids))));
                IF result ? 'error' THEN RAISE EXCEPTION USING ERRCODE='22023'; END IF;
                INSERT INTO api_private.plan_confirmations VALUES(owner_id,plan.id,plan.planned_on,wear);
            END IF;
        END IF;
    END IF;
    result := jsonb_build_object('data',api_private.plan_item(plan),'request_id',request_id);
    UPDATE api_private.mutations m SET response=result WHERE m.user_id=owner_id AND m.operation_id=operation;
    RETURN result;
EXCEPTION
    WHEN invalid_text_representation OR numeric_value_out_of_range OR invalid_parameter_value OR invalid_datetime_format OR datetime_field_overflow
        OR check_violation OR foreign_key_violation OR not_null_violation THEN
        RETURN jsonb_build_object('error',jsonb_build_object('code','validation_failed','message','Invalid plan or wear confirmation','request_id',request_id));
    WHEN unique_violation OR no_data_found THEN
        RETURN jsonb_build_object('error',jsonb_build_object('code','version_conflict','message','Plan changed; reload before editing','request_id',request_id));
END $$;
REVOKE ALL ON FUNCTION app.api_v1_planner(jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION app.api_v1_planner(jsonb) TO authenticated;
