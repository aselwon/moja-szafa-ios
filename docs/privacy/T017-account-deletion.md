# T017 — Account deletion

## Implemented boundary

Account → Delete account explains irreversible data removal and the separate
Apple subscription lifecycle. Cancellation is available before submission. The
user confirms a fresh Apple authorization (including authorization code) or an
email code sent by the gateway to the **existing verified identity**, never an
address supplied by this screen. PL/EN strings include offline/error feedback
through the existing authentication model. Apple state/nonce checks are retained.
No subscription status is consulted. A subscription management link is provided.

The client persists one non-secret operation UUID per subject across timeouts and
restarts. A durable acceptance receipt triggers profile-file removal, injected
offline-store invalidation and Keychain clearing. Local cleanup failures block
the app behind a retry screen; launch retries without another server submission.
The current live composition has no widget/photo cache. Any future composition
must extend `deletionCleanup` for its caches, drafts and app-group/widget storage.
Other devices must clear local data when the server rejects their sessions.

Migration 009 serializes acceptance with profile writes, removes relational data
via existing cascades, retires image publication and keeps an independent deletion
ledger. Server-only functions cannot be called by authenticated clients. One job
per subject deduplicates even a new operation UUID. Profile recreation is rejected.
A five-minute lease, fenced completion and eight-attempt dead-letter limit survive
worker crashes. `backend/deletion/worker.mjs` requires an explicit adapter module;
it cannot silently substitute a mock. The existing image sweeper continues to
remove retired objects after delayed writers and restores.

## Gateway contract (not a deployed endpoint)

All endpoints are HTTPS POST beneath `/auth/v1`, with a bearer session and JSON:

- `deletion/challenge`: `{}` → `{ "challengeID": UUID }`. Rate-limit and send
  a short-lived, purpose-bound code to the account's verified email. For Apple-only
  identities without verified email, require Apple authorization instead.
- `deletion`: `{ "operationID": UUID, "method": "email", "challengeID": UUID,
  "code": string }` or `{ "operationID": UUID, "method": "apple",
  "identityToken": string, "nonce": string, "authorizationCode": string }`.
  Response: `{ "jobID": UUID, "status": "queued" | "succeeded" }`.
- Failures use the existing `{ "error": { "code", "message", "request_id" } }`
  envelope; 401 means rejected identity. Never report completion after only queuing.

The gateway maps the flattened proof into `requestDeletion(..., { operationID,
proof })`. Its identity adapter must validate signature, issuer, audience, nonce,
purpose and subject; reject reused proof except the same operation's retry;
and return `{subject, purpose: 'account_deletion', authenticatedAt: epochMillis}`.
The service independently checks subject, purpose and five-minute freshness.
Before acceptance the adapter must exchange/store Apple revocation credentials in
an encrypted server-side vault independent of profile cascades. Retrying an
already deleted subject must verify proof against this vault without signing the
user in or re-creating the profile. Do not trust a caller-supplied owner UUID.
No proof, authorization code or token is stored in SQL jobs or logs.

`postgresDeletionStore()` uses the service's libpq identity. The worker adapter
exports `identity.revokeSessions(owner)`, `identity.revokeApple(owner)`,
`identity.deleteUser(owner)` and `storage.remove(uploadID)`. Each must be
idempotent, use bounded network timeouts (total attempt below five minutes), and
throw on unconfirmed outcomes. Apple is a no-op only for a verified non-Apple
account; already-revoked credentials count as success only with provider evidence.
`privateDeletionStorage(directory)` supplies the local private-volume adapter.
For other storage providers, `storage.remove` must remove the **entire upload namespace**, including originals,
thumbnails, staging files and configured object versions. Delete the auth identity
only after revocation and file removal. Keep retry evidence until completion;
then remove revocation secrets. Run under a restarting supervisor, alert on
pending age/dead-letter jobs, and requeue only after repairing the cause.

## Backup policy and genuine release blockers

There is no approved production retention duration or deployed authentication
provider adapter in this repository. T013's live composition still fails closed.
This implementation does **not** establish that production Apple revocation,
session invalidation, photo destruction or backup expiration has occurred.

Before enabling deletion, the owner must approve and publish the actual retention
periods for database backups, storage versions, identity vault and minimal deletion
ledger, then configure providers accordingly. Do not promise immediate erasure
from immutable backups. The privacy policy must explain restricted backup access,
expiry and restoration safeguards. Retain minimal deletion tombstones through the
longest backup horizon and delete them afterward under the approved policy.

Restore in isolation. Replay the independently preserved deletion ledger **before**
allowing logins, workers or traffic: delete restored auth/profile data, revoke
credentials, retire image ledgers and sweep every restored object version. A
`succeeded` ledger entry is not permission to skip reapplying deletion to restored
data. Verify no deleted subject can log in, publish a delayed image or replay an
outbox. Record provider settings, restore timestamps and evidence without secrets.
These operational safeguards remain a release blocker until exercised.

## Verification

- `export PATH=/home/harness/.local/bin:$PATH && node scripts/harness-check.mjs`:
  deterministic identity-boundary, retry, interruption, existing image and worker
  tests, localization and structural checks.
- `bash backend/tests/run-tests.sh` on disposable PostgreSQL 15: migration/upgrade,
  cascade, one-job replay, lease fencing and server-only authorization. Added to
  the existing database test runner used by CI.
- Existing macOS CI/Xcode test scheme: new AuthenticationTests cover acceptance,
  unavailable gateway and cleanup recovery. Linux cannot compile SwiftUI.
- On an iPhone with a configured gateway: email and Apple/private relay, wrong
  identity, expired/replayed proof, cancel, offline, lost acceptance response,
  app termination, cleanup failure, subscription management, two devices and
  stale refresh/outbox. Verify second-device sessions and signed image URLs fail.
- With actual providers: interrupt each worker step, restart, inspect both image
  variants/versions, revoke Apple access, confirm all sessions are invalidated,
  exercise dead-letter recovery and the isolated backup restore above.
