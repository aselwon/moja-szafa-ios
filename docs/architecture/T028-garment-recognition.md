# T028 — Garment recognition drafts

## Contract and validation

`backend/ai/recognition.mjs` exports the closed JSON Schema and its dependency-free
validator. `image-analysis-v2` embeds that schema in the system prompt. Required
metadata: category, unique colors, nullable pattern, unique seasons, nullable
integer formality (1–5), finite overall confidence (0–1), and boolean
`multiple_items`. Unknown properties, including brand, price and purchase date,
are rejected rather than silently discarded. Unknown optional attributes use
empty arrays/null; uncertain categories use `other`. A pair of shoes counts as
one garment. Pattern enums constrain AI output; the user's manual pattern field
remains free text.

The executor validates image results before the trusted runtime hook and again
after it, then wraps them as `{schema_version: "garment-recognition-v1",
state: "draft", metadata, requires_correction}`. A permissive runtime hook cannot
bypass validation. Invalid output fails permanently, preserves known usage in
telemetry, and triggers no extra paid repair request. Outfit behavior is unchanged.
Runtime image validators now receive the closed metadata object and must return
that same contract (not an envelope).

Confidence below 0.8, category `other`, or `multiple_items` requires review.
The 0.8 threshold is an explicit initial product rule, not a measured calibration
or accuracy claim. All results, including confidence 1, remain drafts. No AI
result creates a garment or fills price, brand or purchase date.

## Native draft handling

`GarmentRecognition.decodeDraft` independently validates metadata and recomputes
the review requirement. `PhotoImportModel.acceptRecognition(_:for:)` accepts the
worker's **result** object, not its telemetry/output wrapper, for a local draft.
Suggestions persist in a protected atomic sidecar, separate from user-entered
metadata. Reopening restores suggestions, deletion removes them, and photo edits
invalidate them. Existing manually saved metadata takes precedence.

The import form displays editable suggestions and PL/EN review messaging. Low
confidence blocks saving until the user confirms reviewing and correcting the
fields. Confirmation need not invent an edit if the suggestions were already
correct. For multiple garments, no suggested attributes are applied: the user
must enter one garment manually or return to crop the image. Cancellation does
not save metadata. Missing/invalid analysis leaves the manual form available.

## Integration and validation

The native import flow now connects to the owner-scoped backend. It persists a
protected analysis intent and image digest before upload, retries with stable
draft/operation IDs, rotates only the image ID after an expired upload, and
resumes a queued job after restart. Enqueue and result responses must match the
current draft, image and job IDs; the client validates the result again before
persisting suggestions. Editing, manual fallback and removal prevent a late
result from being applied. A result remains a suggestion until the user saves
the garment through the existing form.

Migration 032 adds private expiring recognition drafts and the distinct
`recognition_images` resource command. The recognition RPC scopes enqueue,
result and discard to the authenticated owner and current image. Dispatch checks
that the private draft is still live and its image is ready; discard retires the
upload and cancels queued analysis. The public job listing does not expose the
private result. The gateway bootstrap and the new resource mapping are exercised
by a separate PostgreSQL gateway integration test.

Verified local backend evidence on 2026-11-05:

- `node scripts/harness-check.mjs`: 87/87 tests passed, including recognition
  schema validation, threshold handling, purchase-field rejection and runtime
  hook bypass checks.
- `backend/tests/run-tests.sh` on disposable PostgreSQL 15: clean install,
  populated v001 upgrade, replay, atomic rollback, checksum and schema/security
  contracts, all SQL/concurrency fixtures including recognition drafts, and the
  synthetic recovery drill passed.
- Gateway PostgreSQL integration on a fresh disposable PostgreSQL 15 cluster:
  1/1 passed with recognition prepare/claim/finish/read, owner isolation,
  discard and no-garment-creation assertions.

An earlier focused Release XCTest run passed 53/53 before the latest cleanup
and transport test updates. After those updates, the focused `APIClientTests`
run passed 22/22 on the simulator (`/private/tmp/T028RecognitionAPIFinal2.xcresult`).
The latest `PhotoImportTests` and `GarmentFormTests` have not been rerun after
all current edits, so full native verification remains pending. No external AI
call, AI activation, or deployment was part of these checks, and synthetic
tests do not establish real-image accuracy or confidence calibration.

Remaining acceptance work is to run the focused native import/recognition tests
and macOS CI matrix, then review clear, ambiguous, multi-item and failed-image
flows on an iPhone, including PL/EN, VoiceOver, Dynamic Type, correction gating,
cancellation, manual fallback and restart behavior. Confirm no purchase facts are
populated and no garment is created without explicit user saving. Validate
classification quality and calibration separately with the T033 evaluation set.
