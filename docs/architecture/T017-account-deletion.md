# T017 — account deletion

## Implemented scope and activation gate

Profile → Delete account has PL/EN consequences, export guidance, a cancelable
confirmation and identity confirmation. The Apple subscription management link
is informational: cancellation is never a precondition for deletion. A 202 means
**accepted and blocked**, not that every copy has already been erased. Offline or
unconfigured requests display an error; there is no locally simulated success.

`AppDependencies.authenticated(using:)` composes the client with the existing
approved gateway connection. `live()` remains unconfigured, as in T013. Before
activation, implement the deployment identity, object storage and backup adapters
below. These are genuine missing integrations, not verified production features.
No provider credentials, paid calls or infrastructure changes were made here.

After acceptance the app removes the local profile, photo draft directory and
export spool, clears Keychain and invalidates any attached offline store. Removing
the draft directory also makes late import writes fail (imports do not recreate
it). Local cleanup errors allow cleanup retry without another remote request.
There is no widget implementation/cache yet; its future store must join cleanup.
A crash or lost 202 before cleanup still requires the gateway's deleted-account
recovery flow and device verification; do not activate without testing that path.

## Gateway contract (version 1)

Both routes are same-origin HTTPS POST, bearer authenticated, `Cache-Control:
no-store`. Error bodies contain `code`, `message`, `request_id`; no provider error
or proof is logged. The transport must reject redirects and disable caching.

| Route | Input | Success |
| --- | --- | --- |
| `/v1/account/deletion/challenge` | Empty body | 200 `{id: UUID, method: "email" or "apple", nonce: string or null, state: string or null}` |
| `/v1/account/deletion` | `{operation_id: UUID, proof: {challenge_id: UUID, code?: string, identity_token?: string, authorization_code?: string, state?: string}}` | 202 `{id: UUID, status: "accepted"}` |

UUID strings use lowercase on the wire. Proof body limit: 16 KiB. Challenge expiry
is five minutes, enforced by the identity adapter. UI always requests explicit
confirmation before challenge issuance. Email OTP goes only to the verified linked
address; the client cannot supply an alternative email or account. Apple challenge
returns SHA-256 nonce plus random state; verify Apple signature, issuer, audience,
expiry, nonce, state and **the existing linked subject**, never matching by email.
Exchange the fresh authorization code and retain its revocable token in the
server secret vault before accepting deletion. Never persist proof in the queue.

`startDeletionChallenge(owner)` and
`verifyDeletionChallenge(owner, operationID, proof)` must enforce rate limits,
attempt limits, purpose, owner and expiry. Retain a successful verification receipt
bound to the operation UUID for ambiguous-response retries; it must not authorize
another account/action. A session refresh is not reauthentication. Failed proof
returns 403 and never writes a deletion job. Missing adapters fail closed.

The gateway must check the deletion ledger on **every** API, login, refresh and
signed-object request, not just validate a JWT signature. Only the deletion retry
route may accept proof from a blocked account. Provide a narrowly scoped recovery
receipt/challenge flow after revocation for lost responses; never permit a blocked
account to recreate its profile. This integration is still required in T013's
unimplemented deployment gateway.

## Durable cleanup

Migration 010 tombstones the profile and inserts one job per owner atomically,
serializing against existing profile locks in mutations, uploads and exports.
Different operation IDs for the same owner return the original job. Restrictive
RLS also prevents reads with an old JWT after tombstoning. Export snapshots are
erased immediately and upload publication is fenced. Existing image sweeper must
continue running to remove late writes and expired signed uploads.

Run the trusted deployment module with:

```sh
export PATH=/home/harness/.local/bin:$PATH && node backend/deletion/worker.mjs /absolute/path/to/deletion-runtime.mjs
```

The module exports `identity`, `storage`, `backups`. Libpq supplies the service
connection through operator configuration. The queue uses SKIP LOCKED, five-minute
leases, random completion fences, eight attempts, bounded backoff and dead-letter.
Supervise the process and alert on dead-letter rows and `deletion_worker_unavailable`.
The worker aborts cleanup at four minutes and schedules a retry; adapters must
honor the supplied `{signal}` on all IO. Supervise the process to recover a
process-level hang before lease expiry. A replacement worker reclaims expired leases.
All external operations must be idempotent, including already-absent resources.

Order, with completion recorded only after every step succeeds:

1. `backups.recordDeletion(owner, jobID)`: durable deletion journal outside the
   database restore domain. No images, email or proofs; only necessary identifiers.
2. `identity.revokeAllSessions(owner)`: revoke refresh sessions on every device;
   gateway's ledger check invalidates still-cryptographically-valid access tokens.
3. `identity.revokeAppleTokens(owner)`: revoke all linked Apple grants with the
   configured Apple server credentials. Non-Apple account is an explicit no-op;
   missing Apple credentials or provider failure is an error, never success.
4. `storage.eraseAccount(owner)`: remove originals, cleaned photos, thumbnails,
   candidate images, pending uploads, export spool/archives and object versions;
   fence outstanding uploads and late writers. Wait for or revoke existing signed
   capabilities. Include non-image artifacts added by future features.
5. `identity.deleteAccount(owner)`: remove auth identity and secrets after Apple
   revocation. DB finish deletes remaining owned rows and operator audit entries,
   retaining only the deletion journal and retired upload identifiers for recovery.

Never delete revocation material before step 3. On ambiguous failures repeat the
same account cleanup; do not generate a fresh identity or accept new data. To
recover dead-letter, inspect the failing adapter, fix it, then reset that specific
job's attempts/status under audited operator access. Do not remove the tombstone.

## Backup policy: unresolved release requirement

No approved backup retention duration or deployed provider policy exists in this
repository. Do **not** claim backup erasure or publish an invented duration.
Owner/operator must approve and publish a concrete duration covering database
snapshots/PITR, object versions, auth backups, exported spools, logs and deletion
journals, then configure those durations and capture evidence. The UI makes no
numeric retention promise. Retain deletion markers until all earlier restorable
copies have expired, with tightly restricted access and documented lawful purpose.

Restore into an isolated environment, replay the independently retained deletion
journal and erase matching auth/data/objects **before** exposing API, workers or
signed URLs. Reapply deletions even for jobs previously marked succeeded. Prove
expiry and restore behavior with synthetic accounts and record actual dates.
Policy/implementation agreement remains a release blocker until this is done.

## Verification

- Harness: dependency-free tests for failed proof, no mutation without proof,
  cleanup ordering, each external failure preventing completion, safe HTTP errors.
- Existing PostgreSQL CI: migration fresh/upgrade/replay plus deletion idempotency,
  stale completion rejection, cascade removal, other-owner isolation, surviving
  cleanup ledger. Run `bash backend/tests/run-tests.sh` with PostgreSQL 15.
- Existing macOS CI: compile Debug/Staging/Release and run `AccountDeletionTests`
  (timeout preserves operation UUID, local cleanup retry, unconfigured denial).
- Real iPhone/staging: Apple/private relay and email, wrong-account/expired proof,
  cancellation, offline, timeout after acceptance, kill/relaunch before cleanup,
  concurrent imports/exports, two-device access and outbox replay after deletion,
  worker crash at every step and lease reclaim, all object versions and signed URL
  expiry, Apple grant revocation, Keychain/draft cleanup, Dynamic Type/VoiceOver.
- Backup restore drill and approved retention policy evidence as described above.

The sandbox has no Xcode, Swift toolchain or PostgreSQL tools. Harness success is
not evidence of a compiled iOS app, executed SQL, real Apple revocation or backups.
Both full task acceptance criteria still need the external verification above.
