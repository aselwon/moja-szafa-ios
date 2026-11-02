# T015 — AI privacy settings and dispatch gate

The profile sheet links to Privacy and AI. The authenticated server returns the
recipient, transmitted data, purpose and policy version before offering consent.
Choices are append-only `consent_events` with the full disclosure and operation
UUID. Repeating a mutation returns current state without replaying an older grant.
Account identity comes exclusively from `auth.uid()`. Manual wardrobe APIs do not
require AI consent.

`api_v1_ai_consent` uses the existing RPC success/error envelope. Read request: `{}`.
Write request: `{operation_id: UUID, granted: Bool, disclosure: object|null}`.
Disclosure fields: `policy_version`, `recipient`, `data_description`,
`purpose_description` (all strings). Response data: `{disclosure, granted}`.
Grant requires an exact match to the current disclosure; refusal is always possible.
An ambiguous write keeps its operation UUID for retry while the screen remains
open. The UI does not claim an offline or failed revocation succeeded. On reopening,
it reads authoritative state. The disclosure text must cover both supported app
languages when provisioning the current single disclosure record.

Migration 007 adds no real provider configuration. An authorized operator must
populate `api_private.ai_disclosure` with the approved recipient, actual data scope,
purpose and version after provider selection. Never put a test recipient into a
production environment. Changes invalidate earlier consent by matching the entire
disclosure. No grant, missing configuration or a failed authorization read means
no external AI call. Existing queued jobs without consent evidence fail closed.

Enqueue and consent changes serialize on the account row. Revocation cancels queued
and claimed jobs and releases outstanding usage reservations atomically. Every
worker attempt calls `jobs_authorize_dispatch` before invoking the adapter; it
checks the live lease, account and exact consent event. Old jobs cannot be revived
by regranting consent. A provider request authorized before revocation may already
be in flight and cannot be recalled. The authorization commit is the dispatch
boundary, not a claim of atomicity across PostgreSQL and an external network.
Provider adapters must not maintain independent deferred queues or retry outside
this worker authorization boundary. Cancellation fences late results.

## Verification

- `export PATH=/home/harness/.local/bin:$PATH && node scripts/harness-check.mjs`
  covers structural checks, localization and deterministic worker refusal/error tests.
- PostgreSQL 15: `bash backend/tests/run-tests.sh` covers migration upgrade/replay,
  consent idempotency, revocation, reservation release, stale grants and changed
  disclosures alongside existing queue/concurrency tests. Requires local PostgreSQL
  tools/server; unavailable in this sandbox.
- macOS CI runs ProfileTests/AIConsentTests and the application builds for Debug,
  Staging and Release. Xcode is unavailable in the Linux sandbox.
- On a configured staging build, review PL/EN disclosure, decline, grant, enqueue,
  revoke before dispatch, relaunch and verify cancelled jobs and manual wardrobe
  access. Repeat offline, with expired auth, with large Dynamic Type and VoiceOver.
  Inspect evidence in the owner's consent events. A real provider and device flow
  remains external verification; no API calls or deployments were performed here.
