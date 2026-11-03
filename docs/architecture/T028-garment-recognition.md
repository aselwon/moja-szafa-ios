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

## Integration limits and verification

The existing T027 runtime/storage integration and owner-approved provider are
not configured here. The current job status API does not deliver private result
payloads to iOS; no production caller of `acceptRecognition` exists yet. A trusted
owner-scoped result delivery path must bind job, image revision and local draft
before invoking it, refuse stale completions after edits/account changes, and
honor T015 consent. Do not expose raw worker output or telemetry through the
public job listing. End-to-end recognition is therefore not claimed as working
in a deployed app; this is a real integration gap, not a simulated success.

Local evidence: `node scripts/harness-check.mjs` passes, including closed-schema,
threshold, purchase-field rejection, runtime-hook bypass, and worker tests.
`GarmentFormTests` adds decoding, required review, manual correction,
multiple-item fallback, draft persistence/isolation, edit invalidation and cleanup
tests. These XCTest cases require macOS/Xcode and were not executed on Linux.

Before acceptance in the app:

1. Run the existing macOS CI build/test matrix, including `GarmentFormTests`.
2. Complete the authenticated result delivery integration above and configure
   approved T027 runtime hooks/provider on staging with owner authorization.
3. On an iPhone, analyze clear, ambiguous, multi-item and failed images; confirm
   editable draft behavior, review gating, cancellation, manual fallback, restart
   persistence, PL/EN, VoiceOver and Dynamic Type. Confirm no purchase facts are
   populated and no garment is created without explicit user saving.
4. Measure real classification quality/calibration with the separate evaluation
   dataset; synthetic tests do not establish model accuracy.

No paid APIs, deployments, account changes or external verification were used.
