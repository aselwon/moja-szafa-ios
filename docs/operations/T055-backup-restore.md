# T055 — Backup and isolated recovery

Status: repository procedure and synthetic rehearsal implemented; **operational
acceptance remains unverified**. No backup service, schedule, cloud resource,
production restore or measured production RPO/RTO was created in this task.
ADR-001 is still conditional. The sandbox has no PostgreSQL client/server,
network, storage account or authorized recovery environment. Do not treat a
successful harness check or a small CI rehearsal as evidence of production SLA.

Sources: [SPEC §§5, 7–8](../../SPEC.md), [backend ADR](../architecture/ADR-001-backend.md),
[image implementation](../architecture/T011-private-images.md),
[backend schema](../../backend/README.md). No provider documentation was fetched;
the owner must verify backup/PITR, Auth export, storage versioning and retention
capabilities for the selected provider/plan before executing this procedure.

## Responsibilities and prerequisites

The product owner must assign a named recovery operator and independent reviewer,
approve storage/retention costs and legal retention, and authorize a dedicated
recovery environment. These assignments are currently missing. The operator owns
backup alerts and monthly restore drills; the reviewer approves the evidence and
reopening. Repeat after migration, storage or auth changes and before release.

Use a dedicated recovery project/cluster and private storage namespace, never the
live database or ordinary shared staging. Production copies require explicit
access authorization; staging/dev rehearsals use synthetic data only. Deny public
ingress, mobile access and all outbound calls (AI, email, Apple, webhooks). Stop
workers, Cron, upload writers and cleanup. Recovered leases must not trigger paid
calls or replay deliveries. Use temporary operator access, MFA, audit records and
secret-manager/libpq credentials, never connection strings in commands or logs.
The CI bootstrap is a test-only Auth shim; do not deploy it to a managed service.

## Backup policy to configure and verify

Proposed policy pending owner approval: complete a paired database/object backup
at least every 12 hours, retain 7 daily recovery sets and 4 weekly sets, encrypted
with separately controlled recoverable keys. A 12-hour schedule provides retry
headroom for the **24-hour RPO target**; it is not proof of that target. Alert on
failure immediately and on latest verified common recovery point older than
18 hours; escalate a 24-hour gap as a target breach. Verify a second failure-domain
copy, restricted restore/delete roles, key recovery, retention expiry and capacity.
Never store dumps, object inventories, identifiers or credentials in Git or public
CI artifacts. Store only aggregate, redacted drill measurements in release evidence.

| Component | Required backup and restore evidence |
| --- | --- |
| PostgreSQL | Consistent backup of `app`, `api_private`, `migration_meta`, necessary sequences/functions/RLS/grants, and provider-supported Auth data. Record server/client versions, backup start/end and recovery point, migration checksums, size and archive digest. Keep a tested roles/extensions/configuration inventory; a database dump does not include cluster roles. |
| Photos | Separate encrypted backup of actual object bytes. Current T011 adapter uses a private volume, with `<upload UUID>/original.jpg` and `thumbnail.jpg`; SQL metadata alone is insufficient. Include any future cleaned variant and temporary purchase candidate assets when those features exist. Manifest each opaque key, version, size and SHA-256 in restricted storage. Do not back up signed URLs. |
| Auth/configuration | Provider-supported identity recovery, session revocation, encryption keys and configuration inventory under separate access control. Never assume `pg_dump` alone restores managed Auth or external credentials. |
| Deletion evidence | Append-only journal in a separately protected failure domain, outside the database snapshot and restored storage. It must remain current through incident/reopening, including requests accepted during the outage. See deletion gate below. |

For the current volume implementation, obtain a common recovery point by stopping
all mutations, upload/cleanup processes and workers, draining in-flight writes,
then recording UTC time, taking `pg_dump --format=custom`, copying the volume and
verifying the object manifest before resuming. Record the resulting maintenance
window. `pg_dump` provides database consistency, not cross-storage consistency.
An online provider snapshot/versioning alternative is acceptable only after a
drill proves every referenced ready object exists at the selected point. Do not
silently choose unrelated database and storage snapshots or declare missing
photos acceptable. Raw uploads and orphans are not publishable recovered assets.

Database backup commands use approved libpq configuration and an operator-selected
private output directory; files must be created with `umask 077`. The automated
rehearsal below is deliberately limited to generated databases and test bytes;
it is not a production backup scheduler or cloud connector.

## Recovery sequence and release gates

1. Declare incident and record UTC `incident_at` immediately (RTO includes triage,
   provisioning, download and verification). Freeze source ingress and isolate the
   destination as above. Preserve the source; never run `--clean` against it.
2. Select the newest verified **common** recovery point at/before the incident.
   Verify archive/manifest hashes and encryption-key access. Record actual source
   sizes and throughput. Missing/corrupt artifacts fail closed; try an older complete
   set and report the resulting RPO breach if necessary.
3. Provision a new empty database with compatible PostgreSQL/extensions/roles and
   a new private volume/bucket. Restore with error-on-failure and an atomic database
   transaction where supported (`pg_restore --exit-on-error --single-transaction`).
   On failure discard only the disposable destination and restart; never partially
   reopen. Managed-provider restore must use its validated Auth recovery procedure.
4. Restore object versions from the matched manifest; hash-check **all** referenced
   objects. Check migration ledger and schema/constraints/RLS/grants against the
   recovered application version. Use that version first; do not automatically run
   newer migrations as part of recovery. Check counts and representative histories,
   prices, wear-day deduplication, plans and relationships against pre-recorded
   synthetic canaries. Verify anonymous and cross-owner reads are denied.
5. Replay the independent deletion journal through the cutover watermark before
   enabling any read, login, download or worker. Run the procedure below twice to
   verify idempotence. Missing journal, gaps, or inaccessible object versions block
   reopening; being within the RTO target never overrides deletion safety.
6. Revoke restored sessions and old signed URL capabilities, clear gateway/response,
   mobile sync and widget caches using the account/session reset flow. Reconcile
   post-snapshot consent revocations; leave AI disabled until current consent is
   proven. Quarantine restored jobs/leases, reconcile ambiguous provider attempts
   and billing state against authoritative records before resuming workers. Do not
   blindly clear idempotency keys and accept old client retries.
7. Exercise authenticated read/write and sync canaries on the isolated destination,
   including stale offline writes for deleted identities and garments, denied old
   URLs, live survivor photos, and a new backup of the recovered state. Compare
   manifests after deletions and confirm no public bucket access. No actual paid
   provider call is required or authorized by this document.
8. Operator and reviewer record all gates and approve a separately authorized
   cutover. Record `verified_ready_at` only after all checks pass. Keep the old
   environment fenced; rollback must also replay the current deletion journal.
   Resume ingress and workers in stages, watch failures, then securely destroy
   drill copies and temporary credentials. Record destruction evidence.

## Deletions must survive restore

`app.deletion_jobs` and `api_private.image_uploads` survive ordinary account
cascades, but **both can roll back with a database restore**. They are not an
independent journal. T017's full deletion service and a separately durable journal
are not present here; production reopening is blocked until they are integrated.

The required journal contains an operation UUID, monotonic sequence, request and
completion times, scope (account/garment/object), opaque owner/entity/upload IDs,
all object versions to erase, and a committed high-water mark. No photos, names,
emails or URLs. Persist the deletion intent durably outside the rollback domain
before acknowledging it or deleting source metadata/bytes. Record pending as well
as completed requests. Retain suppression evidence for at least the longest
recoverable backup lifetime plus the restore window, with owner-approved privacy
retention. Encrypt it, restrict access and audit changes. Purge expired backup
copies/versions according to policy; immutable backups require documented expiry
and replay on every restore, not a claim of immediate physical erasure.

The operator validates journal continuity/authenticity, then loads trusted rows
into temporary `recovery_accounts(user_id uuid PRIMARY KEY)` and
`recovery_garments(user_id uuid, garment_id uuid, PRIMARY KEY(user_id, garment_id))`
tables in the same database transaction as
[`replay-deletions.sql`](../../backend/recovery/replay-deletions.sql).
Missing input tables fail SQL execution. The SQL marks matching upload ledgers
retired **before** cascading deletes, invokes canonical garment deletion with both
owner and entity ID checks, and deletes Auth identities with cascading domain deletion. Run as an
authorized recovery administrator; this is not an exposed application RPC.

For surviving accounts, replay preserves scrubbed garment UUID tombstones rather
than physically deleting the identity row. It also fences journaled drafts absent
from the snapshot, so a later offline create cannot resurrect them. The recovery
transaction temporarily sets the same subject context used by the gateway, calls
`app.api_v1_delete_garment`, checks success, and restores its prior subject setting.
A journal entry cannot alter another owner's existing garment. Accounts absent
from the snapshot need no garment row; deleted accounts are handled by the account
replay. A missing or unavailable profile for a surviving identity causes replay to fail rather than
silently claim successful deletion. Ingress must remain fenced throughout.

For each surviving owner with a replayed garment deletion, SQL also scrubs all
restored mutation request/response payloads, invalidates prepared export snapshots,
and cancels and scrubs restored AI jobs. This deliberately invalidates owner-wide
caches instead of relying on incomplete matching of nested garment references.
Other owners' caches and surviving domain records remain unchanged. Mutation and
job operation IDs remain reserved: old requests fail rather than returning private
cached data or executing again. Users must refresh after recovery and resolve
any pending-operation conflict before creating a new intent. AI dispatch receipts,
usage reservations and recorded costs remain intact; recovery does not reset limits.

The SQL is only the relational replay phase, not the complete erasure service.
Before reopening, additionally:

- Enumerate retired upload IDs and independently journaled keys (including assets
  created after the snapshot), erase bytes and **every retained object version**,
  verify absence and retry failures durably. T011's repeated sweep can assist with
  the current volume; future candidate assets need their own cleanup integration.
- Verify SQL payload scrubbing and purge exported archive bytes and any external
  provider/support caches. Handle operational audit/deletion evidence under
  approved retention. Never print private payloads. Retain operation suppression
  identifiers so retries cannot recreate erased data.
- Verify the replayed garment tombstones at the API/sync boundary, including
  future restore and stale-device writes. The synthetic drill checks fresh stale
  create intents against restored and post-backup garment IDs, cached response
  rejection, invalidated exports/jobs and isolation of another owner's caches.
  Provider-managed identities/sessions and archive bytes still require the
  separate reopening checks above; these are not proven by SQL assertions alone.
- Repeat replay through a final watermark while ingress remains fenced. Verify
  other owners are unchanged and interrupted byte deletion resumes idempotently.

## Executable synthetic rehearsal

On a dedicated PostgreSQL 15+ test cluster with client tools and Python 3:

```sh
bash backend/tests/recovery-drill.sh
```

No database name is accepted. The script creates two unique disposable databases,
applies the real migrations, seeds three synthetic owners and opaque image byte
fixtures, dumps the complete source database and copies the private test objects.
It records independent post-backup account and garment deletions, restores into the
empty second database, proves deleted rows initially reappear, replays deletion
twice, verifies owner isolation, retained price and rejected stale garment creates,
erases retired bytes twice,
and checks SHA-256 of surviving original/thumbnail fixtures. These files are byte
fixtures, not real JPEGs; decoder/HTTP authorization tests remain in the T011 suite.
The trap removes only successfully created test databases and temporary artifacts.
The test requires a disposable admin cluster and uses the existing test Auth roles.
It makes no network service calls beyond the configured test PostgreSQL connection.

A focused run on disposable PostgreSQL 15.19 completed with synthetic RPO
0.364083 seconds and RTO 1.869139 seconds, two deletion-replay passes and two
surviving synthetic object files. The fixture contains three synthetic owners,
three snapshot garments and a post-snapshot deleted draft. These measurements
cover only this small local fixture; they do not establish production RPO/RTO.

The existing PostgreSQL CI entry point (`backend/tests/run-tests.sh`) runs this
rehearsal automatically. It prints aggregate JSON timing and fails if the synthetic
24-hour/8-hour bounds are exceeded. The tiny fixture neither validates production
scale nor proves real photo-storage, Auth, journal durability or reopening gates.
Missing tools cause failure rather than a skipped/pass result.

## Measurement and acceptance record

Use UTC clocks with verified synchronization and record these fields in restricted
operational evidence for each real drill:

| Field | Required value / current evidence |
| --- | --- |
| Run ID, operator, reviewer, authorization | Not assigned / not executed |
| App/migration revision, provider, region, PostgreSQL version | Record actual recovered environment |
| DB bytes, object count/bytes, users, garments, history, network profile | Representative workload including 1000 garments and 5 years of history; no measured dataset yet |
| Backup start/end, common `recovery_point_at`, verified artifact IDs | Not measured |
| `incident_at`, restore start/end, deletion watermark, `verified_ready_at` | Not measured |
| RPO | `incident_at - recovery_point_at`; require nonnegative and <= 86,400 seconds for database **and** photos, using the older recoverable point |
| RTO | `verified_ready_at - incident_at`; require nonnegative and <= 28,800 seconds, including deletion replay and all reopening checks |
| Integrity, RLS, deletion, stale-device and session checks | Attach aggregate results and restricted evidence references; no customer records in report |
| Failures and destruction of test copies | Record errors, remediation/retest and cleanup confirmation |

AC1 **needs verification**: database backup and photo strategy plus an executable
isolated synthetic drill are supplied. Run PostgreSQL CI, then execute the full
paired backup/restore in the authorized isolated provider environment and attach
evidence. No real backup or restore has been performed here.

AC2 **needs verification**: relational deletion replay and synthetic timing checks
are supplied. Complete the independent journal and suppression integrations, prove
all erased bytes/versions and stale retries stay inaccessible, and measure both
targets on representative data. No production RPO/RTO result is claimed.
