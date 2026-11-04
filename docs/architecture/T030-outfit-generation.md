# T030 — Validated outfit generation

The trusted AI executor accepts an omitted count as 3, or an integer from 1 to
10. T029 candidate selection still enforces ownership, availability, archive
status and the 40-candidate bound. No UI, migration, provider account or model
selection is added by this task.

`backend/ai/outfits.mjs` defines the closed provider JSON schema and the server
validator. The versioned `outfit-generation-v2` prompt requests `outfits` with
`garment_ids` and `rationale`, plus a nullable `shortfall_reason`. Results cannot
exceed the requested count. Unknown IDs, repeated IDs within an outfit, omitted
pins, invalid fields and unexplained shortfalls fail closed before persistence.
Duplicate outfits are removed by their order-independent ID sets, with a server
explanation if this produces a shortfall. Zero proposals are allowed only with
an explanation; the server never invents garments to fill the requested count.
An empty eligible wardrobe still fails before provider dispatch, as in T029.

Each accepted outfit receives server-derived `complete` and `missing_categories`.
Top + bottom + shoes, dress + shoes and jumpsuit + shoes are complete. Incomplete
suggestions explicitly identify the missing categories; these labels must be
rendered by the consuming UI. Categories and eligibility are read again after
generation, and the trusted runtime must still enforce atomic ownership/status
validation at persistence. Generation neither saves wear events nor changes CPW.

Only a syntactically invalid model JSON body with a completed, metered response
allows one repair request. The executor re-resolves candidates and rechecks
consent/recipient before that request. It sends fresh allowed metadata with a
JSON correction instruction, never the raw invalid response. A second malformed
response fails permanently. Schema/domain errors, refusal, truncation, unknown
usage, transport errors, HTTP errors and timeouts do not trigger repair/retry.

Telemetry records each provider call separately, including unsuccessful JSON
and failed repair usage. **The runtime telemetry sink must deduplicate on
`job_id + attempt + provider_call`**, not only job and attempt. `provider_call` is
1 or 2; the output telemetry describes the final call, while the durable sink
contains both charge records. Budget integration must allow for at most two
metered calls. A failed first telemetry write prevents repair. No raw provider
content is logged.

## Verification and remaining integration

`node scripts/harness-check.mjs` runs injected-transport tests without network or
credentials: defaults/bounds, ten distinct proposals, complete and incomplete
combinations, strict schema, pin/ID validation, deduplication, explained empty
results, repair limit, per-call usage, consent withdrawal and changed candidates.
Existing ownership/archive/laundry and 1000-garment tests remain enabled.

This Linux sandbox cannot run Xcode or verify a production runtime. Run the
existing macOS CI build/tests on the branch. On an authorized staging runtime,
verify the new result fields and telemetry deduplication key, including both
usage records after a JSON repair; verify atomic persistence checks. No paid API
calls, deployments or account changes were performed. Actual model usefulness
remains a separate evaluation, not a result claimed by these deterministic tests.
