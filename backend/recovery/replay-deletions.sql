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

DELETE FROM app.garments g USING recovery_garments d
WHERE g.user_id = d.user_id AND g.id = d.garment_id;
DELETE FROM auth.users u USING recovery_accounts d WHERE u.id = d.user_id;
-- Private idempotency responses can contain resurrected garment metadata.
-- See runbook: invalidate all response caches before opening recovered service.
