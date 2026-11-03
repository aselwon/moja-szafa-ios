# T017 — Account deletion implementation and activation gates

## Implemented behavior

Account → Delete account presents PL/EN consequences and an optional Apple
subscription-management link. Cancelling a subscription is never a prerequisite.
The user signs in again using email or Apple in an ephemeral session, then gives
final destructive confirmation. A different account cannot authorize deletion.
Apple authorization codes remain in memory; they are sent only to the configured
HTTPS authentication gateway, never persisted or logged. The operation UUID is
persisted per account so retrying the screen does not create another intent.

An accepted response means **queued**, not physically erased. The app removes the
account UI, fences refresh, clears Keychain and invokes the configured offline
store's `invalidateAccount()` (including its outbox) and removes the account's
original/edited photo drafts. Import and edit writes check the accepted marker,
so a suspended importer cannot recreate those files after deletion. A durable accepted marker
allows local cleanup to resume on launch if storage fails; the account stays
hidden until cleanup succeeds. The current live composition remains unconfigured,
as in T013. There is no widget cache in this repository; any future cache must be
added to the same cleanup hook before activation. No claim of secure erasure from
flash media or removal of an offline second device's local files is made.

Migration 009 adds a server-only deletion command and persistent stage/lease data.
Acceptance takes the same profile lock used by mutations/publication, tombstones
the account and retires its image uploads. Restrictive RLS policies hide its
content even from an unexpired JWT. Offline mutations reject the tombstone.
The deletion ledger also prevents reprovisioning that same profile UUID.

The worker runs one stage per lease:

1. Revoke **all** authentication sessions and refresh tokens.
2. Revoke **all** linked Apple grants using server-escrowed revocable credentials.
3. Remove original and thumbnail files from the existing private image volume.
4. Delete the authentication identity and its associated provider/contact data.
5. Purge the profile and cascading domain records, plus operator audit rows.

Each external effect must be idempotent. A lost response repeats the same stage;
only a valid, unexpired lease advances it. Provider calls have a 45-second timeout,
leases last two minutes, and each stage has at most eight attempts with backoff.
Exhausted jobs remain in dead-letter; they are never labelled successful. The
existing image sweeper must continue running: retired upload ledgers survive to
remove bytes written by a delayed uploader and to suppress publication after
restore. An already-dispatched external AI request cannot be recalled.

## Gateway contract and integration boundary

`POST /auth/v1/account/delete`, bearer = newly authenticated session.
Request: `{ "operationID": UUID, "appleAuthorizationCode"?: string }`.
Success: HTTP 202 (200 also accepted for replay),
`{ "jobID": UUID, "status": "queued"|"running"|"succeeded"|"failed"|"dead_letter" }`.
Errors use the existing T009 `error.code/message/request_id` envelope and suitable
non-2xx statuses. Do not expose provider errors or credentials.

`backend/deletion/gateway.mjs` provides the request handler, to be mounted in the
**still-unimplemented T013 authentication gateway**. Inject:

- `auth.verifySignature(token)`: verify issuer, audience, signature and expiry;
  return server-derived `userID` and actual authentication time in seconds.
  Refresh/issuance time must never substitute for authentication time.
- `auth.requireActiveSession(identity)`: reject revoked/deleting accounts for new
  requests. A new request requires authentication within five minutes.
- `auth.prepareAppleRevocation(identity, code)`: durably escrow the revocable
  credentials for every linked Apple subject before accepting deletion. Exchange
  a supplied code only for the verified subject, with server-held credentials;
  never infer identity from email. Email reauthentication still requires revoking
  any linked Apple grants. Repeating code exchange must use durable deduplication.
  Failure must reject acceptance, not silently skip revocation.
- `store`: `postgresDeletionStore()` under a dedicated server identity permitted
  to execute the deletion RPC. Never pass client-supplied owner IDs to the RPC.

Receipt recovery first checks the authenticated subject plus original operation
UUID. A revoked but still cryptographically valid/unexpired token can retrieve
only that existing receipt, without new effects. It cannot initiate deletion.
After that token expires, recovery needs a provider-verified receipt-only flow or
support; do not enable normal account reprovisioning to retrieve a receipt.

Run the supervised worker as:

```sh
node backend/deletion/worker.mjs /absolute/path/to/identity-adapter /private/image-volume
```

The executable identity adapter receives `{id, owner, stage, lease_token}` on
stdin and returns JSON `{ "outcome": "success" }` only after the stage's effect
is confirmed. It must implement `sessions`, `apple`, and `identity`; no fake
production adapter is shipped. Other outcomes/timeouts are retried. Tokens and
keys stay in protected server storage, never stdin job payloads, argv or logs.
Apple revocation must precede destroying the credentials needed to revoke it.
A verified absence of linked Apple identities is a valid no-op; an unavailable
provider or missing credentials for a linked identity is a failure.

Alert on queued-job age, expired leases and dead-letter counts. After repairing
an adapter, an authorized operator can reset attempts and requeue the same stage
on a dead-letter row; record this action in the operational audit system without
personal data. Never advance a stage manually merely to clear an alert.

## Backup retention and restore policy — unresolved deployment dependency

There is **no approved deployed backup schedule, retention duration, provider
contract or published privacy policy in this repository**. Consequently this
change cannot assert that backup retention meets policy. The owner must approve
and record actual database, image-volume, auth-provider and escrow retention,
including replicas, snapshots, provider logs and legally required exceptions.
No invented deletion deadline is shown to users.

Before activation, retain an access-restricted deletion ledger independently of
restorable application backups. It contains account/job UUIDs, stage and times,
not wardrobe content or provider tokens. Retain it (and retired image IDs) long
enough to cover the maximum restorable backup age and delayed-write horizon;
then purge identifiers according to the approved policy. The repository does not
automate that retention expiry until those durations are approved.

Restore procedure: keep ingress, authentication, AI dispatch and upload workers
disabled; restore into isolation; merge the authoritative deletion ledger newer
than the backup; tombstone/purge all matching restored accounts and revoke their
restored sessions; retire/sweep image objects and clear restored auth escrow;
verify deleted subjects cannot read, refresh, write or publish; only then reopen
traffic. RLS alone is not enough: service-role workers bypass it. A backup older
than the deletion may lack the ledger entirely, which is why independent replay
is mandatory. Restore replay and independent ledger storage require deployment
work and a recorded drill; neither has been claimed as performed.

## Verification and remaining acceptance evidence

Sandbox: `export PATH=/home/harness/.local/bin:$PATH && node scripts/harness-check.mjs`
passes, including gateway freshness/identity boundaries, receipt replay after
revocation, Apple escrow failures, ambiguous worker commit responses, real
original/thumbnail deletion, repeated removal and stale image leases.

Added XCTest cases cover wrong-account reauth, acceptance/Keychain cleanup,
restart after cleanup failure, network retries preserving UUID/session and the
HTTPS client wire contract. Photo import tests cover deleting originals/edits and
fencing a suspended import after acceptance. Run existing macOS CI for Debug/Staging/Release.
No Xcode or Swift toolchain is available in this sandbox.

Added `backend/tests/deletion.sql` to `backend/tests/run-tests.sh`: migration
replay, tombstone write denial, cross-account isolation, expired/stale leases,
restart, stage progression, cascades, retained ledgers and reprovision denial.
Updated the schema fixture because a deletion job now denies content reads;
normal owner isolation and deletion-receipt isolation remain explicitly tested.
PostgreSQL tools are absent here; run the existing PostgreSQL 15 CI job.

Both original acceptance criteria remain **needs verification**:

- Deploy/connect the actual T013 gateway and identity adapter using approved
  accounts. On signed iPhones test email, Apple/private relay, linked identities,
  stale/wrong reauth, cancellation, offline/retry, app restart and two devices.
  Confirm all old sessions/refresh tokens fail and real Apple grants are revoked;
  inspect database and private image volume after worker completion. Simulate
  process death and provider failures at each stage. Verify pending/dead-letter
  jobs never appear as fully erased. Check PL/EN, VoiceOver and large text.
- Approve actual retention and policy, verify provider expiry settings, and run
  the isolated backup-restore drill above. Capture non-sensitive evidence of
  deletion replay and expired backups. Network, accounts, Apple credentials,
  macOS CI results, physical devices and owner policy approval are unavailable
  in this sandbox. No external API calls, deployment or account changes occurred.
