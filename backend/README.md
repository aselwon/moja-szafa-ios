# T008 — PostgreSQL schema and migrations

This is repository implementation, not a deployed backend. ADR-001 proposes
Supabase conditionally; its approval, actual Auth/Storage setup and staging
verification remain outstanding. SQL targets PostgreSQL **15+** (including
column-specific `ON DELETE SET NULL`). No extensions or paid APIs are required.

## Applying migrations

Use a migration administrator connection configured through libpq's secure
connection facilities. Do not put credentials in commands, source or logs.
After authorization for the target environment:

```sh
bash backend/migrate.sh DATABASE_NAME
```

The database must already provide Supabase `auth.users(id)`, `auth.uid()` and
roles `anon`, `authenticated`, `service_role`. `service_role` must bypass RLS;
never grant it to an app user or ship its credentials to iOS. The `app` schema
is intentionally separate from `public`; exposure through a gateway is a later
explicit configuration step, not part of this migration. No production Auth
objects or roles are created here. Only the disposable test bootstrap supplies
minimal equivalents.

`001_foundation.sql` is the first baseline (profiles). `002_wardrobe.sql` adds
the domain without altering populated profiles. There was no earlier schema in
the repository: “previous version” means the committed 001 baseline, not a
claimed upgrade of a deployed system. `bash backend/migrate.sh DATABASE_NAME 001`
is supported for this upgrade test; specifying an earlier target never rolls
back already applied migrations.

The runner takes a transaction advisory lock, records SHA-256 checksums in a
private migration ledger, skips previously applied unchanged files and rejects
changed historical files. All selected pending migrations and their ledger
entries commit together or roll back together. Fix forward with a new migration
rather than editing an applied file. There is intentionally no destructive down
migration. Take an authorized backup and validate restore before real rollout.

## Access and ownership

All 22 tables enable and force RLS. Authenticated users can read their own rows;
missing identity returns none. Anonymous access and all direct client writes
are denied. `operator_audit` is backend-only. Sensitive writes (billing, usage,
consent, wear events, sync, deletion) cannot be forged by a client. T009 must
implement authenticated API transactions with ownership checks and minimal
server credentials; this schema does not supply that API. A gateway must set
identity from a verified JWT, never from arbitrary request input. The local
`auth.uid()` test shim does not validate tokens and must not be deployed.

Every relational reference includes `user_id`, backed by a composite unique key
on its parent, so even a backend role bypassing RLS cannot join different
owners. Profile identity maps one-to-one to Auth. Record identity is immutable;
updates increment version and preserve creation time. Sync indexes support
`(user_id, updated_at, id)` cursors. Tombstones reject subsequent edits; the API
must still use `WHERE version = base_version`, reject deleted accounts and
resolve conflicts. UUID uniqueness rejects duplicate operations; turning a
retry into the original successful response is API work, not an SQL guarantee.

## Tables and lifecycle

| Tables | Constraints and lifecycle |
| --- | --- |
| `profiles`, `preferences` | One profile and preference record per owner; optional preferences, PL/EN; Auth deletion cascades domain data. |
| `garments` | Integer nullable grosz, PLN, category/seasons/formality checks; availability independent of archive; estimate requires tracking boundary. No derived CPW or AI-supplied counts. |
| `garment_images` | One variant per garment, unique opaque storage key, upload state and metadata; deletion cascades metadata only. |
| `outfits`, `outfit_items` | Unique garment and ordered position within an outfit; deleting a garment removes its relationships. |
| `wear_events`, `wear_event_items` | Owner/request UUID deduplication, local DATE and validated IANA timezone, future days rejected; historical items independent of current outfits. Deleting an outfit clears only its source reference. Deleting an event removes its own items. |
| `outfit_feedback` | Owner-scoped outfit reference and one current rating per outfit. |
| `ai_jobs` | Deduplication, bounded attempts, queue/lease indexes and consistent lease fields; worker transitions and fencing remain T010. No raw prompts/images or provider payloads. |
| `consent_events` | Append-only decisions with policy version and AI recipient; record a new event to revoke consent. Worker consent enforcement remains later work. |
| `planned_outfits` | Calendar date and owner-scoped outfit, no wear side effect; past plans can be retained. |
| `trips`, `trip_items` | Ordered date range, unique packing item, separate packing state. |
| `purchase_candidates` | Expiring temporary object, optional same-owner purchased garment only after purchased status; never counted as an owned garment by itself. |
| `subscription_entitlements`, `subscription_events` | Unique Apple transaction/notification identifiers, environment and lifecycle states; verified server writes only, append-only notifications. Verification is not implemented here. |
| `usage_reservations` | One reservation per job and request, positive units, settlement/release state and expiry. |
| `sync_operations` | Operation UUID deduplication, base/result version and explicit conflict outcome. Entity UUID is a deliberately polymorphic reference; API validates target type/ownership. |
| `deletion_jobs` | Owner UUID intentionally has no profile FK: cleanup must survive account deletion. No photos or contact details retained here. |
| `support_requests` | Request UUID and open/in-progress/closed lifecycle; account deletion cascades content. |
| `operator_audit` | Backend-only append-only audit; actor/target UUIDs intentionally survive deletion and are not user-readable. Retention/purge requires an approved operations policy. |

All tables carry UUID identity, owner, timestamps, version and deletion marker.
Physical deletion is reserved for server cleanup. Append-only evidence rejects
updates, including tombstoning; an authorized retention purge can delete it.
Deleting garment metadata cannot itself delete object-storage bytes. T011/T017
must durably enqueue the storage keys **before** destructive database cleanup,
then delete actual objects and reapply deletions after restore. The surviving
deletion job is a lifecycle anchor, not a completed cleanup implementation.

Wear counts use distinct `worn_on` from live events and live historical items,
never plans or the current outfit. Multiple events on the same day remain
separate so undoing one preserves another. Price/estimate presentation, conflict
resolution at the tracking boundary, and atomic event editing are later domain
work. No fake prior wear dates are generated.

## Verification

```sh
bash backend/tests/run-tests.sh
export PATH=/home/harness/.local/bin:$PATH && node scripts/harness-check.mjs
```

The SQL suite requires PostgreSQL 15, its client tools, and a local test admin
allowed to create databases and the three test roles. It uses libpq environment
configuration (the existing CI job supplies `PGHOST`/`PGUSER`). It creates three
uniquely named disposable databases and removes them on exit. Test roles, if
absent, are created as NOLOGIN; they are not removed because they may already
be shared by other tests. Run on a dedicated test cluster, never production.

Coverage: empty install; populated 001 upgrade with data preservation; schema
parity; replay; checksum rejection; rollback and retry after injected failure;
RLS using non-owner roles; missing/anonymous identity; client write denial;
cross-owner foreign keys through the privileged backend; invalid prices,
currency, availability, estimates, dates and leases; idempotency keys; immutable
evidence/identity/tombstones; version increments; stable historical dates;
outfit edits/deletes, duplicate daily wear and undo; garment/account cascades;
survival of deletion jobs and isolation of the other owner's data.

The sandbox has no `psql` or PostgreSQL server. SQL execution is **not verified
locally**; missing tools fail the runner rather than skip tests. The existing
`.github/workflows/ci.yml` `postgres` job automatically runs this entry point;
no workflow changes are needed. Require that job to pass on PostgreSQL 15 before
accepting the migration execution criterion. Actual Supabase staging integration
must separately validate Auth identity, role grants and storage behavior after
T007 is authorized. The harness check is not a substitute for executing SQL.

## T009 API extension

Migration `003_api.sql` adds the versioned garment list/save RPCs and a private
transactional replay ledger. Migration `005_fix_save_garment.sql` fixes the RPC's
operation-ID lookup without changing the checksum of an applied migration. The
migration runner applies the latest available migration by default. The table and
API boundaries above describe the T008 baseline; direct client table writes
remain denied. See [T009 contract and verification](../docs/architecture/T009-api-contract.md)
and [OpenAPI v1](api/openapi-v1.json) for the implemented surface, configuration,
error envelope and remaining feature endpoints. The test runner now verifies a
populated v002 upgrade and concurrent/post-commit mutation replay as well.

## T010 durable jobs extension

Migration `006_jobs.sql` adds transactional enqueue, fenced claim/completion,
bounded recovery and owner-scoped status discovery. The runner now defaults to
006 and accepts explicit targets 001–006. See
[T010 architecture, worker contract and verification](../docs/architecture/T010-durable-jobs.md).
The SQL test runner includes queue concurrency and restart recovery; the harness
runs dependency-free worker tests. A real provider adapter and staging deployment
remain external feature/infrastructure work, not a default mock implementation.

## T011 private images extension

Migration `008_images.sql` adds a private durable upload/cleanup ledger and fenced
publication of normalized images. The migration runner now defaults to 008.
See [T011 pipeline, HTTP contract and verification](../docs/architecture/T011-private-images.md)
for decoder prerequisites, authenticated signed URLs, persistent storage and the
cleanup worker integration. No storage service has been provisioned or deployed.

## T027 AI provider adapter

The server-only adapter supplies separate image analysis and outfit recommendation
operations, required model configuration, bounded HTTP, safe failures and usage
telemetry. It plugs into the T010 worker through an executable and mandatory
trusted runtime hooks; no provider or mock is enabled by default. See
[T027 protocol, configuration, integration and verification](../docs/architecture/T027-ai-provider.md).

## T016 private data export

Migration `009_exports.sql` adds private, idempotent 15-minute export snapshots.
The migration runner defaults to 009. The export HTTP handler packages JSON and
private garment photos into TAR and requires the current owner's session at both
request and download. See [T016 integration, scope and verification](../docs/architecture/T016-data-export.md)
for runtime composition, supervised cleanup and outstanding staging/device gates.

## T055 recovery rehearsal

[Backup and restore runbook](../docs/operations/T055-backup-restore.md) defines the
paired database/photo strategy, independent deletion evidence, reopening gates and
RPO/RTO measurement. `bash backend/tests/recovery-drill.sh` runs a synthetic restore
on a dedicated PostgreSQL test cluster; the SQL suite runs it automatically.
Production backup scheduling, provider recovery, deletion-journal integration and
measured operational acceptance remain explicitly unverified.

## T017 account deletion

Migration `010_account_deletion.sql` adds the account deletion queue commands,
account tombstones and restrictive read policies. The migration runner defaults
to 010. See [T017 contract, adapters, cleanup and retention gates](../docs/architecture/T017-account-deletion.md).
The HTTP/worker modules require real deployment identity, storage and backup
adapters; they do not simulate successful Apple revocation or backup erasure.


## T026 manual outfits

Migration `012_manual_outfits.sql` adds `api_v1_list_outfits` and
`api_v1_save_outfit`; their request/response schemas are in `api/openapi-v1.json`.
The configured iOS composition root injects this API into the Outfits tab.
The default unconfigured application still reports service unavailable; no demo
backend or deployment was introduced.

Save replaces ordered membership atomically, checks ownership and live garment
records under locks, checks the outfit base version, and uses the existing
per-owner mutation ledger for replay. Archived garments are allowed in manual
outfits and returned with current archive metadata for a visible warning.
Only `outfits` and `outfit_items` change: historical `wear_event_items` do not.
The collage uses the existing private thumbnail reader, without persisting URLs.

Verification on an equipped environment:

- Run `bash backend/tests/run-tests.sh` against disposable PostgreSQL 15 databases.
  The new `tests/outfits.sql` runs on both clean-install and upgrade databases,
  covering create/edit/favorite, replay, conflicts, foreign IDs, invalid selection,
  archive metadata and historical membership preservation.
- Run the existing macOS CI matrix / shared MojaSzafa XCTest scheme; new
  `OutfitsTests` cover validation, timeout retry identity, editing and conflicts.
- With a configured backend, create a named outfit from multiple photographed
  garments, save, reopen, rename, replace an item and toggle favorite. Refresh and
  confirm persistence; select Favorites only. Archive an included garment and
  refresh: confirm the warning on its collage. Record a wear before editing and
  verify that garment history retains the original membership afterward.
- Check Polish/English, dark mode, accessibility text sizes and VoiceOver on iOS.
  Interrupt a save: retry must use the same operation, and cancellation must let
  the user leave the editor. Opening an outfit again resumes an unresolved save.

Sandbox evidence: repository harness passes. Xcode and PostgreSQL executables
are absent here, so build, XCTest, SQL execution and device screenshots are not
claimed. No dependencies were installed and no services were contacted.

Current boundary: outfit writes require connectivity. A failed save and its exact
retry payload remain in the account's in-memory view model, including after the
sheet closes; they are not a durable offline outbox and do not survive process
termination. Refresh the server list after reopening the app to reconcile an
ambiguous save. Existing configured service access remains necessary for the
end-to-end flow.
