-- Short-lived snapshots, never credentials, job payloads or storage capabilities.
CREATE TABLE api_private.data_exports (
    id uuid PRIMARY KEY,
    user_id uuid NOT NULL REFERENCES app.profiles(user_id) ON DELETE CASCADE,
    expires_at timestamptz NOT NULL DEFAULT (clock_timestamp() + interval '24 hours'),
    snapshot jsonb NOT NULL
);
CREATE INDEX data_exports_expiry ON api_private.data_exports(expires_at);
REVOKE ALL ON api_private.data_exports FROM PUBLIC, anon, authenticated;

CREATE FUNCTION app.exports_command(request jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
DECLARE
    owner_id uuid := (request->>'owner')::uuid;
    export_id uuid := (request->>'id')::uuid;
    action text := request->>'action';
    payload jsonb;
    row api_private.data_exports%ROWTYPE;
BEGIN
    IF action = 'sweep' THEN
        DELETE FROM api_private.data_exports e WHERE expires_at <= clock_timestamp()
          OR NOT EXISTS (SELECT FROM app.profiles p WHERE p.user_id=e.user_id AND p.deleted_at IS NULL);
        RETURN 'true'::jsonb;
    END IF;
    IF owner_id IS NULL OR export_id IS NULL THEN RETURN 'null'::jsonb; END IF;
    -- Serializes per-owner creation, limiting snapshots without duplicate retries.
    PERFORM 1 FROM app.profiles WHERE user_id=owner_id AND deleted_at IS NULL FOR UPDATE;
    IF NOT FOUND THEN RETURN 'null'::jsonb; END IF;
    IF action = 'request' AND NOT EXISTS (SELECT FROM api_private.data_exports WHERE id=export_id) THEN
        IF EXISTS (SELECT FROM api_private.data_exports WHERE user_id=owner_id AND expires_at > clock_timestamp()) THEN
            SELECT * INTO row FROM api_private.data_exports WHERE user_id=owner_id AND expires_at > clock_timestamp() ORDER BY expires_at DESC LIMIT 1;
            RETURN jsonb_build_object('id',row.id,'expires_at',row.expires_at);
        END IF;
        payload := jsonb_build_object('schema_version',1,'generated_at',clock_timestamp());
        SELECT payload || jsonb_build_object('profiles',coalesce(jsonb_agg(to_jsonb(t) ORDER BY t.id),'[]'::jsonb)) INTO payload
          FROM (SELECT id,display_name,language,city FROM app.profiles WHERE user_id=owner_id AND deleted_at IS NULL) t;
        SELECT payload || jsonb_build_object('garments',coalesce(jsonb_agg(to_jsonb(t) ORDER BY t.id),'[]'::jsonb)) INTO payload
          FROM (SELECT id,name,category,subcategory,colors,pattern,seasons,formality,price_grosz,currency,brand,purchased_on,availability,archived_at,estimated_prior_wears,tracking_start_date,created_at FROM app.garments WHERE user_id=owner_id AND deleted_at IS NULL) t;
        SELECT payload || jsonb_build_object('garment_images',coalesce(jsonb_agg(to_jsonb(t) ORDER BY t.id),'[]'::jsonb)) INTO payload
          FROM (SELECT id,garment_id,variant,object_key,content_type FROM app.garment_images WHERE user_id=owner_id AND deleted_at IS NULL AND status='ready') t;
        SELECT payload || jsonb_build_object('outfits',coalesce(jsonb_agg(to_jsonb(t) ORDER BY t.id),'[]'::jsonb)) INTO payload
          FROM (SELECT id,name,favorite FROM app.outfits WHERE user_id=owner_id AND deleted_at IS NULL) t;
        SELECT payload || jsonb_build_object('outfit_items',coalesce(jsonb_agg(to_jsonb(t) ORDER BY t.id),'[]'::jsonb)) INTO payload
          FROM (SELECT id,outfit_id,garment_id,position FROM app.outfit_items WHERE user_id=owner_id AND deleted_at IS NULL) t;
        SELECT payload || jsonb_build_object('wear_events',coalesce(jsonb_agg(to_jsonb(t) ORDER BY t.id),'[]'::jsonb)) INTO payload
          FROM (SELECT id,worn_on,timezone,source_outfit_id FROM app.wear_events WHERE user_id=owner_id AND deleted_at IS NULL) t;
        SELECT payload || jsonb_build_object('wear_event_items',coalesce(jsonb_agg(to_jsonb(t) ORDER BY t.id),'[]'::jsonb)) INTO payload
          FROM (SELECT id,wear_event_id,garment_id FROM app.wear_event_items WHERE user_id=owner_id AND deleted_at IS NULL) t;
        SELECT payload || jsonb_build_object('preferences',coalesce(jsonb_agg(to_jsonb(t) ORDER BY t.id),'[]'::jsonb)) INTO payload
          FROM (SELECT id,styles,colors,excluded_categories,notes FROM app.preferences WHERE user_id=owner_id AND deleted_at IS NULL) t;
        SELECT payload || jsonb_build_object('outfit_feedback',coalesce(jsonb_agg(to_jsonb(t) ORDER BY t.id),'[]'::jsonb)) INTO payload
          FROM (SELECT id,outfit_id,rating,reason FROM app.outfit_feedback WHERE user_id=owner_id AND deleted_at IS NULL) t;
        SELECT payload || jsonb_build_object('planned_outfits',coalesce(jsonb_agg(to_jsonb(t) ORDER BY t.id),'[]'::jsonb)) INTO payload
          FROM (SELECT id,outfit_id,planned_on,notes FROM app.planned_outfits WHERE user_id=owner_id AND deleted_at IS NULL) t;
        SELECT payload || jsonb_build_object('trips',coalesce(jsonb_agg(to_jsonb(t) ORDER BY t.id),'[]'::jsonb)) INTO payload
          FROM (SELECT id,destination,starts_on,ends_on,occasions FROM app.trips WHERE user_id=owner_id AND deleted_at IS NULL) t;
        SELECT payload || jsonb_build_object('trip_items',coalesce(jsonb_agg(to_jsonb(t) ORDER BY t.id),'[]'::jsonb)) INTO payload
          FROM (SELECT id,trip_id,garment_id,packed FROM app.trip_items WHERE user_id=owner_id AND deleted_at IS NULL) t;
        SELECT payload || jsonb_build_object('purchase_candidates',coalesce(jsonb_agg(to_jsonb(t) ORDER BY t.id),'[]'::jsonb)) INTO payload
          FROM (SELECT id,name,status,expires_at,purchased_garment_id FROM app.purchase_candidates WHERE user_id=owner_id AND deleted_at IS NULL) t;
        INSERT INTO api_private.data_exports(id,user_id,snapshot) VALUES(export_id,owner_id,payload);
    END IF;
    SELECT * INTO row FROM api_private.data_exports WHERE id=export_id AND user_id=owner_id AND expires_at > clock_timestamp();
    IF NOT FOUND THEN RETURN 'null'::jsonb; END IF;
    IF action='read' THEN RETURN row.snapshot; END IF;
    IF action IN ('request','check') THEN RETURN jsonb_build_object('id',row.id,'expires_at',row.expires_at); END IF;
    RETURN 'null'::jsonb;
END $$;
REVOKE ALL ON FUNCTION app.exports_command(jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION app.exports_command(jsonb) TO service_role;
