-- Explicit projections prevent future columns, auth credentials and operator data leaking.
-- STABLE gives all subqueries one database snapshot. Prices use decimal integer
-- strings to preserve PostgreSQL bigint precision through JSON consumers.
CREATE FUNCTION api_private.export_snapshot(owner_id uuid) RETURNS jsonb
LANGUAGE sql STABLE SET search_path = pg_catalog AS $$
SELECT jsonb_build_object('schema_version',1,'captured_at',statement_timestamp(),
'profiles', (SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY r.id),'[]'::jsonb) FROM
    (SELECT id, display_name, language, city, created_at FROM app.profiles WHERE user_id = owner_id AND deleted_at IS NULL) r),
'garments', (SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY r.id),'[]'::jsonb) FROM
    (SELECT id, name, category, subcategory, colors, pattern, seasons, formality, price_grosz::text AS price_grosz, currency, brand, purchased_on, availability, archived_at, estimated_prior_wears, tracking_start_date, created_at FROM app.garments WHERE user_id = owner_id AND deleted_at IS NULL) r),
'outfits', (SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY r.id),'[]'::jsonb) FROM
    (SELECT id, name, favorite, created_at FROM app.outfits WHERE user_id = owner_id AND deleted_at IS NULL) r),
'outfit_items', (SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY r.id),'[]'::jsonb) FROM
    (SELECT id, outfit_id, garment_id, position FROM app.outfit_items WHERE user_id = owner_id AND deleted_at IS NULL) r),
'wear_events', (SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY r.id),'[]'::jsonb) FROM
    (SELECT id, worn_on, timezone, source_outfit_id FROM app.wear_events WHERE user_id = owner_id AND deleted_at IS NULL) r),
'wear_event_items', (SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY r.id),'[]'::jsonb) FROM
    (SELECT id, wear_event_id, garment_id FROM app.wear_event_items WHERE user_id = owner_id AND deleted_at IS NULL) r),
'preferences', (SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY r.id),'[]'::jsonb) FROM
    (SELECT id, styles, colors, excluded_categories, notes FROM app.preferences WHERE user_id = owner_id AND deleted_at IS NULL) r),
'outfit_feedback', (SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY r.id),'[]'::jsonb) FROM
    (SELECT id, outfit_id, rating, reason FROM app.outfit_feedback WHERE user_id = owner_id AND deleted_at IS NULL) r),
'consent_events', (SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY r.id),'[]'::jsonb) FROM
    (SELECT id, purpose, policy_version, recipient, granted, created_at FROM app.consent_events WHERE user_id = owner_id AND deleted_at IS NULL) r),
'planned_outfits', (SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY r.id),'[]'::jsonb) FROM
    (SELECT id, outfit_id, planned_on, notes FROM app.planned_outfits WHERE user_id = owner_id AND deleted_at IS NULL) r),
'trips', (SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY r.id),'[]'::jsonb) FROM
    (SELECT id, destination, starts_on, ends_on, occasions FROM app.trips WHERE user_id = owner_id AND deleted_at IS NULL) r),
'trip_items', (SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY r.id),'[]'::jsonb) FROM
    (SELECT id, trip_id, garment_id, packed FROM app.trip_items WHERE user_id = owner_id AND deleted_at IS NULL) r),
'purchase_candidates', (SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY r.id),'[]'::jsonb) FROM
    (SELECT id, name, expires_at, status, purchased_garment_id FROM app.purchase_candidates WHERE user_id = owner_id AND deleted_at IS NULL) r),
'subscription_entitlements', (SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY r.id),'[]'::jsonb) FROM
    (SELECT id, product_id, status, expires_at, environment FROM app.subscription_entitlements WHERE user_id = owner_id AND deleted_at IS NULL) r),
'support_requests', (SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY r.id),'[]'::jsonb) FROM
    (SELECT id, subject, message, status, created_at FROM app.support_requests WHERE user_id = owner_id AND deleted_at IS NULL) r),
'garment_images', (SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY r.id),'[]'::jsonb) FROM
    (SELECT id, garment_id, variant, content_type, object_key FROM app.garment_images WHERE user_id = owner_id AND deleted_at IS NULL AND status = 'ready') r));
$$;
REVOKE ALL ON FUNCTION api_private.export_snapshot(uuid) FROM PUBLIC, anon, authenticated;

CREATE TABLE api_private.data_exports (
    id uuid PRIMARY KEY,
    user_id uuid NOT NULL REFERENCES app.profiles(user_id) ON DELETE CASCADE,
    expires_at timestamptz NOT NULL DEFAULT (clock_timestamp() + interval '15 minutes'),
    snapshot jsonb
);
REVOKE ALL ON api_private.data_exports FROM PUBLIC, anon, authenticated;
CREATE INDEX data_exports_expiry ON api_private.data_exports(expires_at) WHERE snapshot IS NOT NULL;

-- Only a gateway with a verified session may supply owner. Never expose as an
-- authenticated-role RPC; operation IDs alone are not bearer capabilities.
CREATE FUNCTION app.exports_command(request jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
DECLARE
    action text := request->>'action';
    owner_id uuid := (request->>'owner')::uuid;
    operation_id uuid := (request->>'id')::uuid;
    row api_private.data_exports%ROWTYPE;
BEGIN
    IF action = 'sweep' THEN
        UPDATE api_private.data_exports e SET snapshot = NULL
        WHERE snapshot IS NOT NULL AND (expires_at <= clock_timestamp() OR NOT EXISTS (
            SELECT FROM app.profiles p WHERE p.user_id = e.user_id AND p.deleted_at IS NULL));
        RETURN 'true'::jsonb;
    END IF;
    IF owner_id IS NULL OR operation_id IS NULL THEN RETURN 'null'::jsonb; END IF;
    -- Serialize requests per account; bound retained snapshots and prevent races.
    PERFORM 1 FROM app.profiles WHERE user_id = owner_id AND deleted_at IS NULL FOR UPDATE;
    IF NOT FOUND THEN RETURN 'null'::jsonb; END IF;
    IF action = 'prepare' AND NOT EXISTS (SELECT FROM api_private.data_exports WHERE id = operation_id) THEN
        IF EXISTS (SELECT FROM api_private.data_exports WHERE user_id = owner_id
            AND expires_at > clock_timestamp()) THEN RAISE EXCEPTION 'export_in_progress'; END IF;
        INSERT INTO api_private.data_exports(id,user_id,snapshot)
        VALUES(operation_id,owner_id,api_private.export_snapshot(owner_id));
    END IF;
    SELECT * INTO row FROM api_private.data_exports WHERE id = operation_id AND user_id = owner_id;
    IF NOT FOUND OR row.expires_at <= clock_timestamp() OR row.snapshot IS NULL THEN RETURN 'null'::jsonb; END IF;
    IF action = 'prepare' OR action = 'check' THEN
        RETURN jsonb_build_object('id',row.id,'expires_at',row.expires_at);
    ELSIF action = 'read' THEN
        RETURN jsonb_build_object('id',row.id,'expires_at',row.expires_at,'snapshot',row.snapshot);
    ELSIF action = 'image' THEN
        -- Revalidate each snapshot reference against current metadata before IO.
        RETURN to_jsonb(EXISTS (SELECT FROM app.garment_images i JOIN app.garments g
            ON g.user_id = i.user_id AND g.id = i.garment_id
            WHERE i.user_id = owner_id AND i.id = (request->>'image')::uuid
            AND i.object_key = request->>'key' AND i.status = 'ready'
            AND i.deleted_at IS NULL AND g.deleted_at IS NULL));
    END IF;
    RETURN 'null'::jsonb;
END $$;
REVOKE ALL ON FUNCTION app.exports_command(jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION app.exports_command(jsonb) TO service_role;
