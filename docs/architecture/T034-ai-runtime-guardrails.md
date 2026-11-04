# T034 — Trusted AI runtime and free-provider guardrails

The worker now has a concrete runtime for normalized private thumbnails, current
owner-scoped wardrobe metadata, recipient authorization and durable telemetry.
The Cloudflare entry point fixes the direct account endpoint and explicitly
selects `@cf/meta/llama-3.2-11b-vision-instruct` for recognition and
`@cf/meta/llama-3.1-8b-instruct-fp8` for outfits. It does not configure AI Gateway,
fallback providers, prepaid credits or a paid plan.

## Admission, settlement and dispatch

Migration 016 installs `api_private.ai_policy` **disabled by default**. Vision has a separate `image_enabled=false` gate. Only the
migration/operator identity can configure it. The public gateway and worker
cannot change the policy. Admission and dispatch lock the policy row, so
concurrent requests cannot overbook per-user or global budgets. Existing
consent checks, idempotency conflicts and transactional job/reservation creation
remain active. Existing pre-migration replay keeps its original reservation units;
new jobs record the call-credit pricing version and reserve repair capacity.
Daily boundaries use UTC.

Policy units are conservative application call credits, **not measured neurons
or a currency spending cap**. Default limits are 10 units per user and 100 units
globally per day. A regular request reserves its configured units; an outfit
request reserves twice that amount for at most one JSON repair. Pending
reservations count against global availability even across midnight. Successful
settlement and failed-job reservation release retain the existing atomic queue
behavior. The per-user count conservatively retains the full reservation for a
potentially charged failed call until the daily boundary.

Immediately before external transmission, the runtime validates the recipient,
current disclosure, consent, account, lease and kill switch, then commits a
unique dispatch receipt. A receipt counts as potentially spent even if the
process dies or the response is lost. Global daily spend is aggregate and
survives account deletion without retaining user identity. An ordinary failure
before dispatch releases its unspent reservation. A second outfit call requires
durable first-call telemetry proving malformed JSON under the same attempt;
a third call and a redispatch after a lost response are denied. There is no
claim of provider exactly-once execution: a crash between receipt commit and
HTTP transmission can consume quota without making a request.

Telemetry is immutable and deduplicated by job, attempt and provider call. It
contains bounded provider/model/prompt identifiers, latency, token usage and
status, never prompts, images, tokens or provider error bodies. Current owner
and garment availability are resolved again by the existing outfit executor
before persistence. Image input uses the upload ID returned by the image API
and can resolve only that owner's current ready normalized thumbnail.

## Native generation/result contract

`backend/api/openapi-ai-v1.json` is the frozen typed contract. The gateway loads
this checked-in allowlist when installed alongside migration 016.

- `POST /rest/v1/rpc/api_v1_generate_outfits` accepts `{request:{operation_id,
  count,pinned_garment_id,preferences:{colors,seasons},occasion:{formality}}}`.
  Count is 1–10; pin is nullable; preference arrays may be empty; formality is
  null or 1–5. Unknown fields, foreign/unavailable pins and invalid enum values
  are rejected. Success data contains `job_id` and current `status`.
- `POST /rest/v1/rpc/api_v1_job_result` accepts `{request:{job_id}}`. Success data
  contains `job_id`, `kind: outfit_generation`, `status`, `result` and
  `error_code`. Result is null unless succeeded; success contains validated
  `outfits` (IDs, rationale, completeness and missing categories) and nullable
  `shortfall_reason`. Foreign jobs return the same `not_found` as missing jobs.

Both use the existing `{data,request_id}` / `{error:{code,message,request_id}}`
envelope, `Content-Profile: app`, and managed-session Bearer authentication.
Admission errors distinguish `ai_disabled`, `quota_exceeded`, `consent_required`
and `validation_failed`; normal authentication/account/internal errors remain.
No worker token, raw prompt, provider response or telemetry is returned. The
T031 manual one-slot replacement flow preserves other IDs and uses the existing
outfit save RPC; no invented AI replacement endpoint is required.

## Deployment

Use the executable `backend/ai/cloudflare-adapter.mjs` with the existing worker.
Required non-secret configuration names:

- `CLOUDFLARE_WORKERS_PLAN=free`: explicit deployment assertion, not an API check.
- `CLOUDFLARE_ACCOUNT_ID`: approved 32-character account ID.
- `CLOUDFLARE_AI_TOKEN_FILE`: absolute private regular file, permissions 0600.
- `PRIVATE_IMAGE_DIRECTORY`: private normalized image storage readable by this
  trusted worker; never expose the directory through a web server.
- Standard libpq service configuration for a separate worker database identity.

The token remains on the server; it is loaded in memory and never logged or
placed on subprocess arguments. The adapter caps output at 1024 tokens and the
provider timeout at 30 seconds. No credentials are part of this repository.
Install Node 22+, PostgreSQL client tools, and the image decoder prerequisites.
Public gateway credentials must not gain worker membership or token access.

Before enabling policy, configure the exact `Cloudflare Workers AI` disclosure,
verify the account is still on Workers Free, install private storage access and
worker credentials, and validate both configured model response contracts.
Cloudflare's Free plan enforces its own 10,000-neuron daily ceiling; above it,
requests fail. A later operator change to Workers Paid would change this
behavior and must not be treated as covered by this application's call budget.
The application does not impose a total Cloudflare-account dollar cap.

## Evidence

Local tests use synthetic identities, images and provider responses. The full
PostgreSQL suite covers clean install, upgrade, checksum/replay, rollback,
existing queue behavior and recovery, plus disabled admission, exhausted-budget
replay, concurrent quota admission, failed reservation release, uncertain-spend
retention, recipient binding, bounded repair, immutable telemetry, kill switch
and cross-owner image rejection. Provider/runtime tests cover the fixed free
model configuration, private token file requirements and normalized input.

No live AI migration, worker activation or vision inference is claimed by the
local tests. A separate hosted probe on 2026-11-04 used the actual provider and
T030 validator with three synthetic garment IDs: one complete outfit passed on
the first call (351 input / 108 output tokens, approximately 5.1 seconds).
The older non-FP8 alias returned HTTP 410 through the compatible endpoint and
was rejected, so it is not a configured fallback. Vision license initialization
and an actual vision contract probe remain prerequisites before `image_enabled` is set true; no license-agreement request has been submitted by this change.

Official sources checked 2026-11-04:

- [Cloudflare OpenAI-compatible endpoints](https://developers.cloudflare.com/workers-ai/configuration/open-ai-compatibility/)
- [Workers AI pricing and free limits](https://developers.cloudflare.com/workers-ai/platform/pricing/)
- [Llama 3.2 vision model](https://developers.cloudflare.com/workers-ai/models/llama-3.2-11b-vision-instruct/)
