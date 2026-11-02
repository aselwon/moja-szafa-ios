# T027 — Server AI adapter

## Implemented scope

`backend/ai/provider.mjs` implements a dependency-free, server-only HTTP adapter
for the Chat Completions JSON protocol. `analyzeImage` and `recommendOutfits`
are separate operations, with separate configured models and versioned prompts.
There is no default vendor, endpoint, model, credential or mock in production.
No provider selection, current model availability, price, retention or live API
compatibility has been verified in this offline task. The owner must approve
those decisions and the T015 disclosure before enabling dispatch.

The adapter sends POST to the exact configured HTTPS URL, with bearer auth,
`model`, `max_tokens`, `response_format: {type: "json_object"}` and system/user
messages. Image messages contain normalized JPEG/PNG data URLs; recommendations
contain JSON metadata. It expects one choice, `finish_reason: "stop"`, a JSON
object in `message.content`, the exact configured model identifier and integer
`usage.prompt_tokens` / `usage.completion_tokens`. Pin the canonical model ID;
aliases returning a different ID fail closed. A provider/model needing a different
protocol requires a tested transport change before use. JSON object parsing is
not feature-schema or outfit-domain validation; mandatory validation hooks below
prevent these raw results from becoming successful jobs.

## Server configuration and worker integration

Supply these values through the server's secret/configuration system, never in
an iOS xcconfig, app resource, job payload, command-line argument or committed
file. No `.env` file is required or provided.

| Variable | Meaning |
| --- | --- |
| `AI_ENDPOINT` | Exact HTTPS Chat Completions URL; no credentials, query or fragment. Redirects are forbidden. |
| `AI_PROVIDER` | Safe provider identifier for telemetry. |
| `AI_RECIPIENT` | Approved recipient matching the current T015 disclosure. |
| `AI_IMAGE_MODEL` / `AI_OUTFIT_MODEL` | Canonical model identifiers chosen on the server. |
| `AI_API_KEY` | Server-only bearer credential. |
| `AI_TIMEOUT_MS` | Entire HTTP exchange deadline, default 30000, maximum 35000 ms. |
| `AI_MAX_OUTPUT_TOKENS` | Output cap, default 2048, maximum 8192. |
| `AI_RUNTIME_MODULE` | Absolute path to a trusted installed server integration module. |

Run the existing worker with executable `backend/ai/adapter.mjs` as its adapter
argument. Existing libpq configuration supplies the queue identity. The executable
reads a single bounded JSON job from stdin and returns the T010 response on stdout.
It fails closed without configuration or any required integration hook. Deployment
must provision the runtime module; this repository does not pretend that storage,
feature validation and a telemetry service have been deployed.

The runtime module must export these async functions:

- `resolveInput(job)`: use the authenticated job owner and stable private resource
  IDs to recheck ownership, account state and availability. For images, load the
  T011 normalized bytes as `{mimeType, base64}`; never forward an EXIF original or
  accept a client-provided URL. For recommendations return `{garments, count, ...}`
  with only the approved metadata/notes (count 1–10). This transport caps metadata
  at 256 KiB and 1000 candidates; category-preserving candidate selection belongs
  to the recommendation feature.
- `authorizeRecipient(job, recipient)`: verify that the configured recipient and
  transmission scope match the authoritative current disclosure and this job's
  consent evidence. Return exactly `true` to permit dispatch. A missing/mismatched
  disclosure must refuse. After resolution and this check the executable calls
  `jobs_authorize_dispatch` again, immediately before the provider call. Do not
  cache permission or implement a separate deferred queue. The existing T015
  authorization commit remains the dispatch boundary; in-flight data cannot be
  recalled after revocation.
- `validateResult(job, result, resolvedInput)`: enforce the feature's schema and
  domain rules (including ownership, availability, IDs, completeness and duplicate
  sets) and return the validated object, or throw. There is deliberately no default
  identity validator. Only the validated object can be persisted as success.
- `recordTelemetry(event)`: durably record safe job ID/attempt, provider, model,
  operation, prompt version, latency, status and token usage. Deduplicate by
  `(job_id, attempt)`. Do not add raw inputs, outputs, URLs, credentials or exception
  messages. Throw on persistence failure; the worker will not report success.

The exported `createAIExecutor` also supports direct trusted composition with
T010 `runOnce`. Its mandatory `authorize(job, recipient)` hook must enforce both
current consent/lease and recipient binding. All hooks are trusted server code,
never client-supplied JavaScript. Hooks must finish promptly within the outer
45-second process limit (HTTP defaults to 30 seconds, leaving time for storage).

## Failure and accounting semantics

Headers and response body share one abortable deadline. Responses are bounded to
512 KiB, image base64 to 4 MiB. Errors expose only safe codes. Malformed JSON,
refusal, truncation, invalid/missing token usage, HTTP errors, timeouts and domain
rejections never become successful analyses. There is no hidden repair or retry.
The executor treats provider failures as permanent, including ambiguous timeouts
and 5xx responses; this avoids automatically repeating a potentially billed call.

Usage is measured from provider counts, never estimated from text or filled with
zero on failure. Unknown usage is `null`. Valid counts survive a later result
rejection. Successful private job output includes `{result, telemetry}` and is
persisted by existing fenced `jobs_finish`; status APIs expose neither. Attempt
telemetry also goes to the mandatory sink, including failures where possible.
Prices, cost conversion, quota policy and filling the existing `ai_jobs` summary
columns are not claimed here; they require the separately approved pricing and
accounting implementation.

A hard process kill, crash or lost completion can still trigger T010 lease
recovery and another paid call. The protocol does not assume provider idempotency;
exactly-once external billing is not guaranteed. Sink or database failure after a
provider response can also leave usage incomplete. Verify operational monitoring
and reconciliation before production; local reservation settlement is separate
from provider billing. No automatic retry in this adapter overrides T010 recovery.

## Verification and external gates

`node scripts/harness-check.mjs` includes dependency-free deterministic transport
fixtures: distinct operation/model/prompt mapping, configuration refusal, input
limits, malformed/refused/truncated output, missing/invalid usage, oversized
responses, hanging headers/body, abort, safe errors, no internal retries, consent
and ownership refusal, domain rejection accounting, worker completion and safe
executable startup failure. These tests make no network requests and contain no
real credentials. Mock transports exist only in tests.

Before deployment, an authorized operator must select a provider/model based on
current documentation, evaluation, retention and price; install the approved
T015 disclosure and trusted runtime hooks; then validate the actual protocol,
normalized-image resolution, recipient binding/revocation, durable usage records,
provider charges and worker crash recovery on staging. No paid calls, account
changes, deployment or external verification were performed. Require existing
GitHub validation/PostgreSQL and macOS Debug/Staging/Release CI jobs to pass; Xcode
and hosted CI are not available as local evidence in this Linux sandbox.
