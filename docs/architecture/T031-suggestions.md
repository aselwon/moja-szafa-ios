# T031 — Suggestions and manual replacement

Today reads the latest completed T030 outfit result. Cards use the existing
private WardrobeThumbnail/OutfitCollage pipeline, never generated garment images.
The UI resolves IDs against the current account wardrobe, rejects unavailable,
archived, unknown or repeated items, and derives missing categories locally.
An incomplete outfit stays explicitly labelled. A manual replacement changes one
slot, preserves the other IDs and order, and hides the now-stale AI rationale.
The searchable, paginated picker remains usable after a result-service failure.
Previously loaded cards are retained on errors. New results replace the cards on
refresh; refreshing an unchanged result preserves local edits.

Saving uses the existing idempotent outfit editor model. An ambiguous save locks
replacement and wear until the exact payload is retried. The suggestion-specific
RPC locks garment rows and validates current availability within the save
transaction; manual outfit editing retains its existing archive semantics.
Generation, replacement and saving never record wear. Wear today explicitly
writes an immutable ID snapshot and Gregorian local date/timezone to OfflineStore.
The local success state prevents double taps; the existing outbox retains its
operation UUID for sync retries. Success means recorded locally, not server sync.

## RPC contracts

Both RPCs use the existing authenticated PostgREST `request` JSON argument and
`{data, request_id}` / `{error: {code, message, request_id}}` envelopes.

- `api_v1_latest_suggestions`: request is exactly `{}`. Data is null when no
  completed result exists, otherwise T030's `{outfits, shortfall_reason}` result.
  Each outfit contains `garment_ids` (UUID array), `rationale`, `complete` and
  `missing_categories`. Input payloads and telemetry are never returned. Only the
  authenticated active owner's nondeleted successful outfit-generation jobs are
  considered, ordered by completion time then ID descending.
- `api_v1_save_suggestion`: same request/response contract as
  `api_v1_save_outfit` (SaveOutfit / Outfit). Adds atomic availability and archive
  checks for new mutations. Successful retries return the original response even
  if availability subsequently changes. Existing ownership/version checks apply.

Migration 014 is included in the migration runner. SQL regression tests cover
owner isolation, output minimization, account deletion, eligibility and replay.

## Verification

Run `node scripts/harness-check.mjs` with the harness Node PATH. This checks source
registration, localization, secret scanning and existing offline backend tests;
it does not compile Swift or execute PostgreSQL tests.

Run the existing macOS CI scheme for SuggestionsTests: single-slot replacement,
AI failure fallback, duplicate/unknown/unavailable IDs, incomplete categories,
ambiguous save replay and offline wear persistence across restart/local midnight.
Run `bash backend/tests/run-tests.sh` against disposable PostgreSQL databases for
migration and RPC tests. Neither Xcode nor PostgreSQL tools exist in this sandbox.

On a configured simulator/device, seed a completed T030 result and real private
images. Open Today, save, replace one item, record wear and verify history after
restart/sync. Disconnect the result service after loading and verify manual
replacement still works with cached garments. Check PL/EN, VoiceOver, large text,
dark mode, unavailable thumbnails, cancellation and pagination.

## Integration boundaries

This task consumes persisted results; it does not introduce a generation/admission
endpoint, AI replacement provider, or paid calls. Replacement is manual as allowed
by the specification. Trusted T030 runtime/admission configuration remains an
external integration prerequisite. AppDependencies.live() remains deliberately
unconfigured under the existing environment policy; configured authenticated
composition wires the real RPCs. No production end-to-end result is claimed.
