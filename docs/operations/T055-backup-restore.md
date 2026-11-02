# T055 — Backup and recovery runbook

Status: repository procedure and synthetic integration drill implemented; **operational
acceptance needs verification**. No backup service, schedule, storage replica, deletion
journal or recovery environment has been provisioned. No actual service restore or
RPO/RTO measurement was performed in the sandbox. PostgreSQL tools, cloud access and
authorized infrastructure are unavailable. Do not interpret CI fixture timings as
production recovery evidence. This document covers T055 only and does not change
backlog status or implement the account-deletion service from T050.

## Recovery boundary and proposed policy

Targets from SPEC §8: **RPO ≤24 hours**, **RTO ≤8 hours**. These are proposed targets,
not an SLA. The owner must approve retention, cost, region, responders and access
before provisioning. Follow the conditional [backend ADR](../architecture/ADR-001-backend.md)
and [image implementation](../architecture/T011-private-images.md); the implemented
storage adapter is a private persistent POSIX volume, not a configured managed bucket.

| Component | Backup and restore requirement |
| --- | --- |
| PostgreSQL | Consistent full backup of application, private API/queue/upload ledgers, migration ledger, Auth and relevant storage metadata. Preserve schema, functions, constraints, RLS and grants. Include every migration, not just public tables. Provider-managed Auth/roles/extensions need a provider-supported recovery path; an application-only SQL dump cannot reconstruct the service. |
| Photos | Independent encrypted volume snapshots/replica for all committed normalized originals, thumbnails and any cleaned variants. Database backup contains keys, not image bytes. Preserve object keys, lengths and SHA-256 inventory at the same recovery point. Never back up raw camera uploads or signed URLs as necessary recovery data. |
| Configuration | Versioned deployment/configuration and migration revision; inventory of roles, extensions, service schedules and auth settings. Secrets remain in the approved secret manager with a separately tested recovery mechanism, never Git or a dump report. |
| Deletions | Independently durable, ordered journal of accepted deletion requests and object tombstones, outside the database/volume restore boundary. Recover the latest journal, never only the copy inside the selected old backup. |
| Clients | Local outboxes are not server backups. Expired sessions, deleted accounts and tombstones must reject stale writes after restore. Clear/reconcile stale client and widget caches during recovery validation. |

Proposed schedule: coordinated database + image recovery point every 12 hours, with
an alert if the latest **verified complete pair** is older than 18 hours; page before
24 hours. A failed copy must not advance the successful-backup watermark. Prefer
provider PITR and versioned images where available, but verify actual scope, retention
and cost before relying on either. Proposed rolling retention: 7 daily recovery
points, subject to owner/privacy approval; no indefinite archive by default.

Encrypt backups in transit and at rest; separate backup read/write and restore roles
from the application role, require MFA for operators, audit actions without logging
payloads or credentials. Keep at least one copy in a separate failure domain from the
primary database and volume. Confirm region and key recovery. Backup retention and
immutability must be compatible with the approved privacy policy: inaccessible
expired copies are purged on schedule, and a restored copy is never served before
deletion replay. Retain minimal deletion evidence until **all** backups, replicas,
exports and retained recovery environments capable of resurrecting those objects
have expired, plus an approved safety margin. Legal/privacy owner must approve this
window; do not purge the existing `image_uploads` retired records independently.

## Create and verify a recovery point

1. An authorized operator identifies the environment, database, private volume,
   migration revision, backup destination and recovery-point ID. Record UTC times and
   aggregate counts only in the report; keep inventories with identifiers private.
2. For the current volume adapter, stop admission of writes/uploads, drain in-flight
   writes, stop workers and cleanup, and ensure no writer can publish or remove bytes.
   Readiness/maintenance state must survive an operator disconnect. Record the
   beginning of this consistent point conservatively. Never `cp` a live volume while
   database and cleanup operations continue.
3. Capture a transaction-consistent PostgreSQL backup and the frozen image volume.
   On a permitted vanilla PostgreSQL environment, the database primitive is
   `pg_dump --format=custom --file=/secure/backup/database.dump DATABASE_NAME`;
   credentials come from secure libpq facilities, not command-line URLs. For the
   managed service, use its supported backup/export mechanism, preserving required
   Auth/Storage schemas and roles. Do not use test bootstrap in a service environment.
4. Use the approved encrypted snapshot/backup facility for the volume. Store checksums
   for the archive and every referenced ready image, key/size inventory, database
   version, extensions, migration checksums, completion timestamps and deletion-journal
   watermark in an access-controlled manifest. Do not put this manifest in Git.
5. Verify all live ready image keys resolve with the expected bytes; exclude pending
   uploads from the usable recovery point. Missing/corrupt originals invalidate the
   pair; regenerating a thumbnail cannot repair a missing original. Inventory and
   quarantine extra files for cleanup. Verify the remote copy/checksums and that the
   database archive is readable. Archive readability alone is not a restore test.
6. Resume services only after recording success/failure and ensuring the primary is
   healthy. Record pause duration; if it is unacceptable at production scale, validate
   a coordinated snapshot/PITR design before adoption. Alert on backup failure and
   keep the previous verified pair. Exercise recovery monthly and after schema,
   storage or backup-provider changes.

## Independent deletion journal and mandatory replay gate

The existing `app.deletion_jobs` and `api_private.image_uploads` survive some database
cascades, but **cannot protect requests created after the backup when that database
is rolled back**. T050/operations integration must durably record accepted requests
in a separate failure domain before acknowledging deletion. Required minimal fields:
operation UUID, monotonically ordered sequence, accepted UTC time, scope (account,
garment/image or other supported record), owner UUID, target UUID/object keys and
application state. No email, photos, notes, signed URLs or tokens. Restrict and audit
access; identifiers remain private data. Acceptance of a request must not outrun
journal durability. Retry with the same operation UUID; do not claim distributed
atomicity between the journal and database without implementing reconciliation.

During restore, obtain a verified complete journal through the cutover watermark,
including pending requests, not only successful jobs. Missing journal continuity,
unknown scope or unavailable deletion processing **blocks reopening**. Reconcile new
requests arriving during the incident before lifting maintenance mode. Account
requests revoke Auth sessions and remove/disable the identity through the supported
Auth service, cascade application records and purge all associated image keys.
Individual deletions must use their domain operation, preserve ownership checks and
record sync tombstones. Also invalidate exports, caches and temporary candidates as
applicable. Do not replace the service deletion workflow with blanket ad hoc SQL.

Retire matching upload operations before cleanup so stale writers cannot publish.
Drain image cleanup to completion, verify both original and thumbnail are absent,
and verify any other variant/provider object is absent. Preserve tombstones and
retry failed removals idempotently. Repeat replay and cleanup: no records or bytes
may return and unrelated owners must be unchanged. A storage restore **after** replay
requires another sweep (existing retired upload records support this). Restore must
not mark deletion complete solely because a SQL row disappeared. Do not reuse stale
queue leases or automatically replay ambiguous external AI/payment side effects.

## Isolated restore exercise and incident procedure

1. Declare incident/start the RTO clock, assign incident lead, recovery operator and
   privacy verifier. Block traffic/writes and outbound AI, email, payment calls,
   webhooks, Cron and workers. Preserve incident evidence. For an exercise, use an
   isolated account/network with synthetic data; never copy customers into ordinary
   staging. Recovery of real data requires a separately authorized restricted zone.
2. Select the newest verified complete database/image pair within the RPO window.
   Verify archive checksums, key access, journal continuity and destination identity.
   Create a **new empty target**, private volume and isolated credentials. Never
   restore over the source. Do not expose restored services to users or public URLs.
3. Restore database using the provider-supported flow. For the synthetic/local full
   archive, `pg_restore --exit-on-error --single-transaction --dbname NEW_TARGET
   /secure/backup/database.dump` is the primitive. Restore the paired volume; validate
   extensions, roles, grants, RLS and migration checksums. Do not use `--clean` on a
   running service or silently ignore errors. Apply any required forward migrations
   using the versioned runner only after baseline integrity is verified.
4. With traffic still blocked, replay the independent deletion journal as above and
   drain cleanup. Invalidate restored sessions and old signed capabilities through
   supported auth/key rotation procedures. Verify deleted accounts cannot sign in,
   read or submit pre-incident offline operations; re-check owner isolation. Keep
   workers stopped until restored jobs/reservations and uncertain side effects have
   been reconciled. Revalidate current AI consent before any resumed dispatch.
5. Validate counts and checksums against the manifest minus legitimate deletions;
   inspect all ready image references. Test both owners, revoked access, duplicate
   replay, wear-day/CPW consistency, plans and preferences, offline retry and account
   deletion. Do not use restored app tables alone as the oracle. Record failures and
   remediation. RTO ends only when these checks pass and the service is safe to use,
   including deletion replay, not when `pg_restore` exits.
6. Incident lead and privacy verifier record the cutover journal watermark and go/no-go.
   Reconcile writes accepted after the recovery point (including client outboxes)
   without resurrecting tombstones. Document unrecoverable data since the point.
   Re-enable dependencies in stages, monitor errors/queues and retain a rollback
   route. Rollback to an older copy must repeat the same deletion gate.
7. For an exercise, never route production traffic. Remove disposable databases,
   image volumes, test credentials and protected temporary artifacts after recording
   evidence. For an incident, retain only approved evidence and expire old copies
   under the retention policy. Assign unresolved failures and repeat the exercise.

## Measurement and evidence

RPO = incident UTC time minus the **oldest recoverable point across database and
images**, not the time a backup upload finished. This formula is valid only for a
validated consistent pair; inconsistent backups fail regardless of age.
RTO = safe-service verification UTC time minus incident declaration UTC time,
including provisioning, key retrieval, restore, replay and checks. Record component
phase times as well. `backend/recovery/metrics.mjs` evaluates the 24 h / 8 h boundaries
and refuses overall success without verified deletion replay. Timestamp arithmetic
cannot prove the validity of its evidence inputs.

Fill this report after an authorized exercise; all fields currently **not measured**:

| Evidence field | Required entry |
| --- | --- |
| Execution | Date, operator, verifier, environment, isolated target identity, source revision |
| Scale | Database bytes/rows, image count/bytes, user/garment/history distribution, compute and network profile; include 1000 garments and 5 years of history |
| Backup | Protected manifest/archive references and hashes, database/image consistent points, last verified completion, retained-copy locations |
| Recovery | Incident, provisioning start/end, DB and image restore end, replay end, validation end, safe-service time (UTC) |
| Privacy | Journal continuity/cutover watermark, requested/applied counts, pending/failed count (must be zero), byte absence and stale-client/access tests |
| Integrity | Schema/RLS/ownership results, live image checksum coverage, row reconciliation, queue/consent validation |
| Result | Measured RPO seconds ≤86400 and RTO seconds ≤28800; pass/fail, failures, corrective owner and rerun reference |
| Cleanup | Target/artifact disposal evidence and residual retention expiry |

Report only sanitized aggregate evidence in the repository/PR. Keep detailed private
inventories in the approved operations store. Owner must name responders and approve
backup retention and journal hosting before operational acceptance.

## Repository checks and acceptance

```sh
export PATH=/home/harness/.local/bin:$PATH && node scripts/harness-check.mjs
# Dedicated local PostgreSQL test cluster only; PGHOST must be localhost/loopback.
export PATH=/home/harness/.local/bin:$PATH && node backend/recovery/drill.mjs --synthetic-local-only
```

The drill creates uniquely named disposable source/restore databases and private temp
volumes, installs the actual migrations, backs up the full synthetic database and
image bytes, restores both, and demonstrates post-backup account and garment deletion
replay from a separate fixture journal. It exercises actual PostgreSQL image cleanup,
access denial, retained-owner access, duplicate replay and bytes reintroduced after
cleanup. It outputs scoped synthetic timings and removes its artifacts. Test Auth is
minimal and image bytes are opaque fixtures: this is not a provider Auth restore,
JPEG decoder test, production journal implementation or capacity benchmark. The
existing T011 tests cover image decoding separately. It requires PostgreSQL client
utilities and a dedicated local test administrator; it installs no dependencies.
The CI `postgres` job runs it; missing prerequisites or assertion failures fail it.

| T055 criterion | Status and completion path |
| --- | --- |
| Database backup, image strategy and isolated restore exercise | **Needs verification.** Procedure/strategy and executable synthetic drill exist. Require green PostgreSQL CI, then provision authorized backups and execute the isolated representative service exercise with protected manifests and integrity evidence. |
| Measured RPO 24 h / RTO 8 h; reapply deletions after restore | **Needs verification.** Metric boundary tests and synthetic replay checks exist. Implement/verify independent durable deletion-journal integration, then measure the full representative exercise and prove all post-backup deletions remain absent before cutover. |

No external acceptance is claimed. Missing infrastructure, journal integration and
measured exercise evidence are real release blockers, not criteria waived by this PR.
