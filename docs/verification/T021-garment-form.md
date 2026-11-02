# T021 — Garment form verification

## Implementation

From Wardrobe → Add photos, open Garment details on a processed photo draft.
The native PL/EN form offers name, category, multiple colors, pattern, multiple
seasons, optional formality, brand, optional PLN price and optional purchase date.
Cancel discards unsaved edits. Save retains input on failure and reports success
only after the account's SQLite snapshot and outbox transaction has committed.
The photo draft UUID identifies the garment; the existing outbox provides the
operation UUID and replay semantics. Saved draft markers survive restart, and
photos remain local pending the separate upload/finalization integration.

Configured authentication now retains one OfflineStore per account instead of
using the read-only API repository. Unconfigured release services still fail
closed. Returning to the wardrobe triggers its existing load/sync path.

Price parsing constructs Int64 grosz directly from ASCII digits, accepting comma
or dot and up to two fractional digits. Empty is nil; zero is zero. Signs,
grouping, exponent notation, extra decimals and overflow are rejected. Purchase
dates are Gregorian calendar days serialized as YYYY-MM-DD, with no timezone
conversion. Optional fields can be cleared explicitly.

GarmentSuggestions accepts only descriptive AI attributes, all editable. It
cannot supply brand, price or purchase date. Live analysis/job-to-form wiring
belongs to T025; this task does not invoke AI or claim a live analysis result.
Manual entry works with no suggestions.

Migration 009 extends the existing save, list and snapshot functions. It keeps
owner checks, version conflicts, tombstones and replay handling, validates the
new attributes, preserves metadata when legacy clients omit keys, and returns
all fields. Old queued payloads retain their original encoding. New forms send
explicit nulls/empty arrays to clear optional metadata. No applied migration was
modified. The migration-count assertion now expects nine migrations.

## Evidence available in this sandbox

- `export PATH=/home/harness/.local/bin:$PATH && node scripts/harness-check.mjs`
  passes (repository checks, worker/image/AI adapter tests).
- `git diff --check` passes.
- XCTest sources cover exact price boundaries, nil vs zero, validation, manual
  correction of every AI attribute, legacy encoding, save failure/retry, metadata
  persistence/reconciliation, and saved photo markers.
- SQL tests cover full save/list/snapshot round trips, replay, malformed metadata,
  legacy updates and explicit clearing. They run in both fresh and upgraded
  databases through `backend/tests/run-tests.sh`.
- Swift/XCTest and PostgreSQL tests have **not** run here: `xcodebuild` and `psql`
  are unavailable. No dependencies, services or accounts were provisioned.

## Required external verification

1. Run the existing macOS CI Debug/Staging/Release build-and-test matrix. Inspect
   GarmentFormTests, OfflineStoreTests and PhotoImportTests in the xcresult.
2. With PostgreSQL 15 tools and a disposable local test cluster, run
   `bash backend/tests/run-tests.sh`. Confirm clean install, upgrades, ownership,
   replay and the new garment-form SQL suite pass before applying migration 009
   to an authorized environment.
3. On an iPhone/simulator with a configured account, import a photo and open the
   form. Fill every field; save in airplane mode, reopen the app and reconnect.
   Verify one garment, one replay-safe operation and unchanged metadata. Check
   empty price, zero, 12,34 / 12.34, invalid text and excessive precision.
4. Toggle purchase date off and on; test a leap day and switch timezone after
   saving. Verify the stored calendar day stays unchanged.
5. Run PL and EN in light/dark appearance, largest accessibility text and
   VoiceOver. Verify labels, all controls and Save/Cancel remain reachable; color
   selection must work using spoken labels alone. Capture screenshots from that
   actual build (none were produced in this sandbox).
6. Supply GarmentSuggestions in a test host, correct category/colors/pattern/
   seasons/formality, and verify the corrected values are saved. Confirm brand,
   price and purchase date remain empty until manually entered.

These checks are pending evidence, not claimed device or CI results. Production
backend/auth configuration and photo upload wiring remain existing dependencies.
