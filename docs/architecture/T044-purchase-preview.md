# T044 — Temporary purchase preview

A photo and manually entered garment details create an owner-scoped temporary
purchase candidate. It is absent from owned wardrobe, wear history, outfit
membership and CPW until the user explicitly confirms ownership. The app never
claims that this photo was recognized or predicts future cost per wear.

## Frozen feature boundary

`backend/api/openapi-purchases-v1.json` defines three authenticated RPCs:

- `api_v1_purchase`: create/list/get/confirm/discard. Mutations carry a durable
  operation UUID; confirmation additionally requires `confirmed: true`.
- `api_v1_purchase_fit`: enqueue a budgeted `purchase_fit` job for a live ready
  candidate; accepts only candidate and operation UUIDs.
- `api_v1_purchase_fit_result`: owner-only job status and validated result.

`/v1/purchase-images` mirrors the private normalized-image API, using
`candidate_id` during preparation. It has no public object URLs. Every signed
capability is owner-bound, expires after 60 seconds and still requires current
managed-session authentication. Existing image normalization strips metadata;
server decoding and byte bounds remain mandatory.

The single private upload ledger now has exactly one parent: owned garment or
purchase candidate. Its global UUID namespace prevents collisions between the
two storage families. Creating a candidate does not create a placeholder garment.
Candidate expiry is server-assigned seven days after creation. Discard, expiry
and account deletion revoke image reads; the existing cleanup worker fences and
removes bytes. Confirmed photos instead follow their new garment lifecycle.

Confirmation locks the candidate and ready upload, inserts the garment and image
variants, and transfers upload ownership in one database transaction. Candidate
state deduplicates simultaneous confirmations from different devices, even with
different operation UUIDs. A lost response replays the stored mutation. The price
is integer grosz/PLN; confirmation creates no wear events or projected CPW.

## Actual AI path

Purchase matching uses the configured text model, not a new provider or paid
plan. Only explicit candidate metadata and a bounded selection of eligible owned
garments enter the prompt. The candidate remains separate; output garment IDs
must all refer to currently available owned items. The worker resolves data again
after the provider call. Candidate expiry/discard/conversion and current consent
are checked before dispatch. Results compute completeness with the hypothetical
candidate while preserving its separate ID.

The job uses the existing durable consent, kill switch, quota and receipt guards.
It reserves two application call credits: one initial call and at most one JSON
repair, admitted only after durable evidence of malformed JSON. A third call or
uncertain-response redispatch is denied. Vision can remain disabled. This change
does not enable or claim validation of any visual-recognition model.

## Native behavior and lifecycle

The Wardrobe navigation bar opens Before buying. Users select a photo, enter
metadata, inspect AI matches against real wardrobe photos, optionally compare
manually, and confirm purchase through an explicit confirmation dialog. AI failure,
missing consent, quota, unavailable service, pending jobs and offline state remain
visible; none are replaced with fabricated results.

Protected local journals are isolated by gateway and account. Create/upload,
confirmation, discard and AI admission preserve their operation UUIDs across
navigation/relaunch; pending jobs poll their existing ID. Polling is bounded to
60 two-second observations and resumes explicitly. Account-view teardown cancels
work and account-bound token closures prevent cross-account publication. Successful
uploads remove the local draft photo; account deletion removes remaining drafts.

Exports include candidate metadata and still-live temporary original photos in
`purchase-photos/`, separately from owned `photos/`. Each image is reauthorized
before and after storage reads. No signed URL, credential or raw prompt is exported.

## Validation and integration

The isolated branch includes unpublished dependency integration commits for PR72,
PR68, PR69 and PR74. Publish only the purchase feature commit after reconciling
those dependencies with current main; do not publish duplicate dependency diffs.
Apply migration 018 before enabling the new gateway RPC allowlist/resource command.
The normal private-image cleanup worker must run against the updated schema.

Local verification: complete fresh/upgrade/replay PostgreSQL 15 suite in a
disposable container, including four concurrent confirmation connections; owner
and foreign-image checks; explicit confirmation; image transfer and expiry;
export projection; text-only purchase dispatch and repair-budget fencing.
The JavaScript harness and Debug build-for-testing pass. Nine Swift regression
tests compile (durable create/upload retry, confirmation retry, wire nullability,
job resume without duplicate admission, corrupt-journal fail-closed behavior,
stale/failed advice removal and competing photo-selection cancellation).
Runtime simulator execution and live end-to-end provider acceptance remain to be
performed in the coordinated CI/runtime window. No live database migration,
provider request, deployment, paid-plan change or planning-status update was made.
