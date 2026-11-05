# Managed account erasure runtime

This change supplies concrete adapters and tests; it does not activate the worker
or claim production erasure is complete. No real identities or provider tokens
were deleted during validation.

## Trust boundaries

Apply `backend/deploy/neon-erasure.sql` after the gateway bootstrap and app
migrations. Provision a separate LOGIN role with NOINHERIT, NOBYPASSRLS and only
membership in `szafa_erasure`. Do not grant that role to the public gateway. The
worker uses `neonErasureStore()`; each libpq call explicitly assumes this narrow
role. Worker queue operations cannot request a new deletion. The gateway's
separate fresh reauthentication bridge is described below.

Every adapter receives the claimed owner, job UUID, current lease fence and abort
signal. SQL rechecks and locks the queue row before privileged operations. Session
revocation expires only that owner's managed sessions. Apple-linked identities
fail closed until a real Apple token revocation adapter is available.

`neonIdentity()` accepts a project-scoped Neon Editor API key loaded with
`privateManagementKey()` from an operator-owned mode0600 file. The key is never a
branch storage credential, client session, command argument or logged value.
Requests use only the fixed Neon management API origin, reject redirects, and
have bounded deadlines. A successful response, 404, or connection failure is
never sufficient evidence: the trusted database must confirm identity absence.
The deployment SQL also refuses `finish` while the managed identity exists.

The concrete operator module is `backend/deletion/neon-runtime.mjs`, loaded by
`node backend/deletion/worker.mjs backend/deletion/neon-runtime.mjs`. It requires
`ERASURE_RUNTIME_ENABLED=true`, the dedicated worker's `DATABASE_URL` (Neon host,
`sslmode=verify-full`), an existing absolute `PGSSLROOTCERT` CA file,
`NEON_PROJECT_ID`, `NEON_BRANCH_ID`, `NEON_MANAGEMENT_KEY_FILE`,
`PRIVATE_IMAGE_DIRECTORY`, `EXPORT_DIRECTORY`, `ERASURE_JOURNAL_DIRECTORY`,
`ERASURE_ACK_DIRECTORY` and `ERASURE_REPLICA_ID`. Paths must be absolute. The module
checks its database login is NOINHERIT, not superuser/BYPASSRLS/database owner,
belongs to `szafa_erasure`, and does not belong to gateway/service roles before
claiming anything. It maps the connection string into a private libpq child
environment; credentials never appear on command arguments. Missing configuration
or credentials stops startup with a generic error. Do not reuse the public
gateway login or enable either runtime before filesystem permissions and the
independent journal are ready.

## Private bytes and concurrent work

Install `npm ci --prefix backend/storage --no-audit --no-fund` on Node22 with a
C++ build toolchain and Python. Pinned `fs-ext` supplies POSIX flock. Storage must
be a local POSIX filesystem, not NFS. The writing Node process owns the file
descriptor; a helper-process lock would permit late writes after helper death.
Lock files under the private image directory's `.locks` must never be removed
while any service is running.

Both image uploads and export builds/streams acquire the same owner lock through
`privateFiles()`. Image claims are checked after acquiring it. Erasure waits for
existing writers, checks the tombstoned job's live lease, removes the database's
owner-specific image inventory and owner-labeled export spools, and fsyncs
directory removals. New uploads cannot pass the committed deletion tombstone.
Export streaming rechecks authorization against the ledger on each chunk.

Before enabling the worker, drain the old gateway and sweep legacy `export-*`
spools that lack owner UUIDs. The adapter refuses to attest complete erasure while
such unattributed spools exist. Run gateway and worker under compatible dedicated
filesystem permissions; neither directory may be served as public static files.

## Fresh managed reauthentication

Apply `backend/deploy/neon-deletion-reauth.sql` after the bootstrap/app migrations.
The existing native endpoints are `POST /v1/account/deletion/challenge` (empty
body) and `POST /v1/account/deletion` with `operation_id` and
`proof: {challenge_id, code}`. Routes remain disabled unless the operator sets
`ACCOUNT_DELETION_ENABLED=true` after the cleanup worker and journal are ready.

The challenge derives its recipient from the managed verified user, binds the
owner and original managed session, expires after five minutes, allows five
verification attempts, and enforces three sends per owner/hour with a one-minute
resend delay. It never accepts an email or owner from request JSON. Apple-linked
accounts remain blocked while Apple revocation is unavailable.

The gateway delegates sending and verification to Managed Better Auth's existing
`/email-otp/send-verification-otp` (`type: sign-in`) and `/sign-in/email-otp`
endpoints. The actual feature branch OpenAPI was read without authentication on
2026-11-04 to confirm these routes and the managed session's `createdAt` field.
No custom OTP store, code generator or session token is introduced. The returned
provider cookie is checked by live `/get-session` and never returned to the app.
Database acceptance requires a different same-owner managed session created
after the challenge, then consumes the challenge, expires that temporary proof
session and commits the deletion tombstone in one transaction. A current ordinary
session alone is insufficient. Logout is also attempted on every obtained proof
session, including rejected exchanges.

The first attempt binds the operation UUID. A consumed challenge can return only
that operation's original receipt while the original managed session remains
live; the consumed receipt survives challenge expiry and cleanup until identity
deletion cascades it. No second OTP is consumed. After session revocation,
normal authentication rejects it. A lost response after full revocation cannot
be acknowledged through a revoked credential. The native session-invalidated
cleanup path must handle that state. A provider timeout before atomic acceptance
requires a new challenge; the gateway does not invent a successful proof.

Local HTTP tests use the real ManagedAuth HTTP/cookie implementation and real
PostgreSQL, with a synthetic external provider. Wrong codes, old/same/foreign
sessions, expired challenges, bounded attempts, receipt replay and immediate RPC
denial are exercised. Real managed email delivery/sign-in remains untested because
no real email or login was authorized for this implementation.

## Independent journal and activation gaps

`localDeletionJournal()` writes a minimal owner/job record using exclusive
temporary files, fsync, atomic no-overwrite hard links and directory fsync.
Concurrent identical retries are accepted; conflicting existing records stop
deletion. The journal directory must already exist with mode0700.

The local adapter alone is insufficient. `replicatedDeletionJournal()` additionally
requires an exact SHA256/replica-bound acknowledgement from the independent host.
`journal-replicator.mjs` runs on the Mac, pulls at most 500 pending records through
the existing authenticated SSH connection, writes/fsyncs/read-verifies each
canonical record, and only then sends its acknowledgement to the VPS's SSH-only
`journal-receiver.mjs`. No inbound Mac port or public listener is created. Records
contain only version, owner UUID and job UUID. Acknowledgements contain version,
job UUID, exact canonical payload SHA256 and configured replica UUID.

The actual VPS→Mac one-shot synthetic drill passed on 2026-11-04: an intentionally
lost acknowledgement left deletion blocked despite the durable Mac copy; retry
verified the same bytes and acknowledged safely. Wrong hashes/replicas and changed
records fail closed. While the Mac is offline, `deferReplica` leaves the task
queued for five minutes without consuming the destructive-cleanup attempt budget.
No session, file or identity deletion precedes the independent acknowledgement.

After an initial automatic review rejection, the user explicitly approved the
one-minute/login replication service and UUID-only data flow. It is installed as
`~/Library/LaunchAgents/pl.moja-szafa.erasure-journal.plist`, with code and records
in `~/Library/Application Support/MojaSzafa/erasure-journal/`. The original
Documents location blocked background module loading; only this app's newly
created files were relocated, preserving originals and changing no privacy
settings. The actual launch agent then copied and acknowledged a synthetic test
record successfully. No real account deletion was performed. The review package
and original copies remain outside Git in the workspace's
`private-runtime/erasure-journal/` directory. Service logs contain only counts and
generic errors; no record payload or credential is logged.

These are independent durable copies, **not immutable against administrators**.
The existing root SSH identity is privileged. Restrict access and review a
dedicated restricted transport identity before broader operation. Keep markers
until all earlier database/photo/auth recovery points have expired; no invented
retention duration or automatic purge is configured. During recovery, keep all
ingress/workers/file serving disabled, load verified independent records, restore
their deletion tombstones, and rerun the guarded cleanup before reopening. Do not
disable the managed identity erasure trigger to reuse the generic auth-shim drill.
Loss/corruption of the independent journal blocks reopening until reconciled.

Production activation still requires a project-scoped management key,
reviewed worker filesystem permissions and backup
retention/recovery procedure, plus Apple credentials if Apple identities are
enabled. Do not enable cleanup with a fake/no-op journal. No unrelated R2 bucket
is used by this implementation.

## Validation

Synthetic tests cover private-key/configuration rejection, stale fences,
ambiguous provider responses, journal conflicts and parallel retries, an actual
separate lock-owning process killed mid-operation, deletion racing a paused image
decoder, and preservation of another owner's files. Dedicated PostgreSQL15 tests
apply the deployment SQL twice, exercise a NOINHERIT worker login, prove owner and
lease isolation, expire sessions, detect Apple links, and refuse premature finish.
The provider-shaped fixture tables exist only in a disposable local database.

The current local PostgreSQL run passed both `backend/gateway/postgres.test.mjs`
and `backend/gateway/erasure-postgres.test.mjs` against disposable PostgreSQL 15.
The erasure suite verifies provider identity cascade, followed by acceptance using
the operation-bound capability receipt after session revocation; wrong capability,
operation and challenge reuse are rejected without consuming another OTP or
creating another deletion job. The focused Release run passed 25 native tests: 7
`AccountDeletionTests` and 18 `APIClientTests`, including logged-out startup
recovery. It verified that an unaccepted deletion retains its journal and photos,
an accepted receipt completes cleanup, another owner's data remains untouched,
and corrupt journal data is not erased. The result bundle is
`/private/tmp/T017GlobalRecoveryRelease.xcresult`. The repository validation
harness passed 86/86.

This is local integration evidence only. No worker, erasure SQL or challenge route
has been activated in staging or production; no real Apple-linked identity or
provider account was touched. Activation still depends on the management
credential, Apple revocation integration/credentials for Apple-linked users,
approved backup retention, and a restore/replay drill.
