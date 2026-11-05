-- Recovery-only SQL. Caller supplies trusted, independently retained deletion
-- evidence in temporary tables recovery_accounts(user_id uuid) and
-- recovery_garments(user_id uuid, garment_id uuid), inside one transaction.
-- Keep ingress, workers and storage serving disabled until bytes are purged.
-- Capture upload IDs BEFORE cascades; the ledger deliberately survives them.
UPDATE api_private.image_uploads u
SET state = 'retired', fence = NULL, next_cleanup_at = clock_timestamp()
WHERE EXISTS (SELECT FROM recovery_accounts d WHERE d.user_id = u.user_id)
   OR EXISTS (SELECT FROM recovery_garments d
              WHERE d.user_id = u.user_id AND d.garment_id = u.garment_id);

-- Use the same scrubbed tombstone and relationship cleanup as ordinary deletion.
-- A physical DELETE would allow a stale device to recreate the restored UUID.
-- This also fences a draft created after the snapshot, absent from this backup.
DO $$
DECLARE
    deletion record;
    outcome jsonb;
    previous_subject text := current_setting('request.jwt.claim.sub', true);
BEGIN
    FOR deletion IN
        SELECT d.user_id, d.garment_id FROM recovery_garments d
        JOIN auth.users u ON u.id = d.user_id
        WHERE NOT EXISTS (SELECT FROM recovery_accounts a WHERE a.user_id = d.user_id)
          AND NOT EXISTS (SELECT FROM app.garments g
              WHERE g.id = d.garment_id AND g.user_id <> d.user_id)
    LOOP
        PERFORM set_config('request.jwt.claim.sub', deletion.user_id::text, true);
        outcome := app.api_v1_delete_garment(jsonb_build_object(
            'operationID', gen_random_uuid(), 'garmentID', deletion.garment_id));
        IF outcome->'data' IS DISTINCT FROM 'true'::jsonb THEN
            RAISE EXCEPTION 'Recovery garment deletion failed';
        END IF;
    END LOOP;
    PERFORM set_config('request.jwt.claim.sub', coalesce(previous_subject, ''), true);
END $$;
DELETE FROM auth.users u USING recovery_accounts d WHERE u.id = d.user_id;
-- Private idempotency responses can contain resurrected garment metadata.
-- See runbook: invalidate all response caches before opening recovered service.
