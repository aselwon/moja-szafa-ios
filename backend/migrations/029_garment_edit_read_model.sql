-- Expose the complete existing form value and version; edits must not clear unseen attributes.
-- T037: explicit estimates do not create or rewrite journal events.
CREATE OR REPLACE FUNCTION api_private.wardrobe_item(g app.garments) RETURNS jsonb
LANGUAGE sql STABLE SET search_path = pg_catalog AS $$
    SELECT jsonb_build_object('id',g.id,'name',g.name,'category',g.category,
        'initialWearHistory',CASE WHEN g.tracking_start_date IS NULL THEN NULL ELSE jsonb_build_object('count',g.estimated_prior_wears,'startDate',to_char(g.tracking_start_date,'YYYY-MM-DD')) END,
        'availability',g.availability,'priceGrosz',g.price_grosz,'brand',g.brand,
        'colors',g.colors,'seasons',g.seasons,'archived',g.archived_at IS NOT NULL,
        'version',g.version,
        'formMetadata',jsonb_build_object('colors',g.colors,'seasons',g.seasons,'pattern',g.pattern,
            'formality',g.formality,'brand',g.brand,'purchased_on',to_char(g.purchased_on,'YYYY-MM-DD')),
        'imageID',(SELECT u.id FROM api_private.image_uploads u
            JOIN app.garment_images i ON i.user_id = u.user_id AND i.garment_id = u.garment_id
                AND i.object_key = u.id::text || '/thumbnail.jpg'
            WHERE u.user_id = g.user_id AND u.garment_id = g.id AND u.state = 'ready'
                AND i.variant = 'thumbnail' AND i.status = 'ready' AND i.deleted_at IS NULL
            ORDER BY u.id LIMIT 1));
$$;
REVOKE ALL ON FUNCTION api_private.wardrobe_item(app.garments) FROM PUBLIC, anon, authenticated;
