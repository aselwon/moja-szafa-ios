-- Tickets contain no exported payload or public capability. Expiry is never extended by retry.
CREATE TABLE api_private.exports (
 user_id uuid PRIMARY KEY REFERENCES app.profiles(user_id) ON DELETE CASCADE,
 id uuid NOT NULL UNIQUE, expires_at timestamptz NOT NULL
);
REVOKE ALL ON api_private.exports FROM PUBLIC, anon, authenticated;
CREATE FUNCTION app.api_v1_request_export(request jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
DECLARE owner_id uuid := auth.uid(); rid uuid := gen_random_uuid(); row api_private.exports%ROWTYPE;
BEGIN
 IF owner_id IS NULL THEN
  RETURN jsonb_build_object('error',jsonb_build_object('code','unauthorized','message','Sign in required','request_id',rid));
 END IF;
 IF request IS DISTINCT FROM '{}'::jsonb THEN RAISE EXCEPTION 'Invalid request' USING ERRCODE = '22023'; END IF;
 PERFORM 1 FROM app.profiles WHERE user_id = owner_id AND deleted_at IS NULL FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Account unavailable' USING ERRCODE = '22023'; END IF;
 INSERT INTO api_private.exports AS e(user_id,id,expires_at)
 VALUES(owner_id,gen_random_uuid(),clock_timestamp() + interval '15 minutes')
 ON CONFLICT(user_id) DO UPDATE SET id = excluded.id, expires_at = excluded.expires_at
 WHERE e.expires_at <= clock_timestamp();
 SELECT * INTO row FROM api_private.exports WHERE user_id = owner_id;
 RETURN jsonb_build_object('data',jsonb_build_object('id',row.id,'expires_at',row.expires_at),'request_id',rid);
END $$;
REVOKE ALL ON FUNCTION app.api_v1_request_export(jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION app.api_v1_request_export(jsonb) TO authenticated;

-- STABLE gives every collection one statement snapshot. Explicit field allowlists
-- prevent future credentials/internal columns from silently entering the export.
CREATE FUNCTION app.export_snapshot(owner_id uuid, export_id uuid) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog AS $$
 SELECT jsonb_build_object('schema_version',1,'generated_at',statement_timestamp(),
 'profiles', (SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY r.id),'[]'::jsonb) FROM (SELECT id,display_name,language,city FROM app.profiles WHERE user_id = owner_id AND deleted_at IS NULL) r),
 'garments', (SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY r.id),'[]'::jsonb) FROM (SELECT id,name,category,subcategory,colors,pattern,seasons,formality,price_grosz::text AS price_grosz,currency,brand,purchased_on,availability,archived_at,estimated_prior_wears,tracking_start_date,created_at FROM app.garments WHERE user_id = owner_id AND deleted_at IS NULL) r),
 'outfits', (SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY r.id),'[]'::jsonb) FROM (SELECT id,name,favorite FROM app.outfits WHERE user_id = owner_id AND deleted_at IS NULL) r),
 'outfit_items', (SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY r.id),'[]'::jsonb) FROM (SELECT id,outfit_id,garment_id,position FROM app.outfit_items WHERE user_id = owner_id AND deleted_at IS NULL) r),
 'wear_events', (SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY r.id),'[]'::jsonb) FROM (SELECT id,worn_on,timezone,source_outfit_id FROM app.wear_events WHERE user_id = owner_id AND deleted_at IS NULL) r),
 'wear_event_items', (SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY r.id),'[]'::jsonb) FROM (SELECT id,wear_event_id,garment_id FROM app.wear_event_items WHERE user_id = owner_id AND deleted_at IS NULL) r),
 'preferences', (SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY r.id),'[]'::jsonb) FROM (SELECT id,styles,colors,excluded_categories,notes FROM app.preferences WHERE user_id = owner_id AND deleted_at IS NULL) r),
 'planned_outfits', (SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY r.id),'[]'::jsonb) FROM (SELECT id,outfit_id,planned_on,notes FROM app.planned_outfits WHERE user_id = owner_id AND deleted_at IS NULL) r),
 'trips', (SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY r.id),'[]'::jsonb) FROM (SELECT id,destination,starts_on,ends_on,occasions FROM app.trips WHERE user_id = owner_id AND deleted_at IS NULL) r),
 'trip_items', (SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY r.id),'[]'::jsonb) FROM (SELECT id,trip_id,garment_id,packed FROM app.trip_items WHERE user_id = owner_id AND deleted_at IS NULL) r),
 'outfit_feedback', (SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY r.id),'[]'::jsonb) FROM (SELECT id,outfit_id,rating,reason FROM app.outfit_feedback WHERE user_id = owner_id AND deleted_at IS NULL) r),
 'consent_events', (SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY r.id),'[]'::jsonb) FROM (SELECT id,purpose,policy_version,recipient,granted,created_at FROM app.consent_events WHERE user_id = owner_id AND deleted_at IS NULL) r),
 'purchase_candidates', (SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY r.id),'[]'::jsonb) FROM (SELECT id,name,status,expires_at,purchased_garment_id FROM app.purchase_candidates WHERE user_id = owner_id AND deleted_at IS NULL) r),
 'photos', (SELECT coalesce(jsonb_agg(jsonb_build_object('id',i.id,'garment_id',i.garment_id,'variant',i.variant,'object_key',i.object_key) ORDER BY i.id),'[]'::jsonb)
 FROM app.garment_images i JOIN app.garments g ON g.user_id=i.user_id AND g.id=i.garment_id
 WHERE i.user_id=owner_id AND i.deleted_at IS NULL AND i.status='ready' AND g.deleted_at IS NULL))
 FROM api_private.exports e JOIN app.profiles p ON p.user_id=e.user_id
 WHERE e.user_id=owner_id AND e.id=export_id AND e.expires_at>clock_timestamp() AND p.deleted_at IS NULL
$$;
REVOKE ALL ON FUNCTION app.export_snapshot(uuid,uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION app.export_snapshot(uuid,uuid) TO service_role;

-- Lightweight fencing during streaming; do not rebuild the entire wardrobe per photo.
CREATE FUNCTION app.export_access(owner_id uuid, export_id uuid, photo_id uuid, storage_key text) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog AS $$
 SELECT EXISTS (
  SELECT FROM api_private.exports e JOIN app.profiles p ON p.user_id=e.user_id
  WHERE e.user_id=owner_id AND e.id=export_id AND e.expires_at>clock_timestamp() AND p.deleted_at IS NULL
  AND (photo_id IS NULL OR EXISTS (
   SELECT FROM app.garment_images i JOIN app.garments g ON g.id=i.garment_id AND g.user_id=i.user_id
   WHERE i.id=photo_id AND i.user_id=owner_id AND i.object_key=storage_key
   AND i.status='ready' AND i.deleted_at IS NULL AND g.deleted_at IS NULL
  ))
 )
$$;
REVOKE ALL ON FUNCTION app.export_access(uuid,uuid,uuid,text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION app.export_access(uuid,uuid,uuid,text) TO service_role;
