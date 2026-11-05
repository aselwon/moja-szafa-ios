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
    affected_owners uuid[] := '{}';
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
        affected_owners := array_append(affected_owners, deletion.user_id);
    END LOOP;
    -- Restored responses can contain deleted attributes even when the domain
    -- rows are scrubbed. Keep operation IDs, but invalidate owner-wide caches:
    -- guessing which nested payload references the garment is not sufficient.
    UPDATE api_private.mutations SET request='{}'::jsonb, response=NULL
        WHERE user_id=ANY(affected_owners);
    UPDATE api_private.data_exports SET snapshot=NULL,
        expires_at=least(expires_at,clock_timestamp())
        WHERE user_id=ANY(affected_owners);
    -- Fence restored workers before scrubbing their input/output. Keep IDs,
    -- accounting and dispatch receipts so recovery cannot reset spending limits.
    UPDATE app.ai_jobs SET status='cancelled', lease_token=NULL,
        lease_expires_at=NULL, finished_at=coalesce(finished_at,clock_timestamp()),
        error_code='recovery_invalidated'
        WHERE user_id=ANY(affected_owners);
    UPDATE api_private.job_payloads p SET input='{}'::jsonb, result=NULL
        FROM app.ai_jobs j WHERE j.id=p.job_id AND j.user_id=ANY(affected_owners);
    PERFORM set_config('request.jwt.claim.sub', coalesce(previous_subject, ''), true);
END $$;
DELETE FROM auth.users u USING recovery_accounts d WHERE u.id = d.user_id;
-- Export spool bytes and external provider caches still require the runbook's
-- independent byte-erasure and session-revocation gates before reopening.
