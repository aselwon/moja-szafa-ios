# T008 — PostgreSQL schema and migration contract

## Scope and prerequisites

The two transactional migrations in `backend/migrations` implement the 22 tables
in SPEC §5. PostgreSQL **15 or later** is required (column-specific `ON DELETE
SET NULL`). They follow the conditional Supabase choice in ADR-001; no service
has been provisioned and T007's owner approval/staging verification is still open.
No extensions, downloads or paid APIs are required by these migrations.

Production prerequisites are Supabase's `auth.users`, `auth.uid()`,
`authenticated` and `service_role` (a trusted backend role with BYPASSRLS).
`backend/tests/bootstrap.sql` is **only a disposable test fixture**, not an auth
implementation to deploy. The `app` schema is intentionally separate from
`public`. T009 must explicitly wire the authenticated API/schema exposure.

## Tables, ownership and lifecycle

| Group | Tables and rules |
| --- | --- |
| Identity | `profiles` references `auth.users`; `preferences` has one row per owner. Account deletion cascades owned data. |
| Wardrobe | `garments` stores integer grosz or NULL, PLN only, independent availability/archive/tombstone, optional brand/date and prior-wear estimate with required boundary date. No stored AI-derived CPW counter. |
| Images | `garment_images` references an owned garment, unique object key and variant; pending/ready/deleting/failed lifecycle. Keys are storage identifiers, never signed URLs. |
| Outfits | `outfits`, `outfit_items`; unique garment and position per outfit. Removing a garment removes its relationships. |
| History | `wear_events` has stable local DATE, validated timezone and owner/request UUID uniqueness; future wear dates are rejected. `wear_event_items` is an independent snapshot, never a reference to current outfit membership. Deleting an outfit clears only the optional source ID; deleting a garment removes its history links as SPEC requires. |
| Plans/travel | `planned_outfits`, `trips`, `trip_items`; owned outfit/garment references, date-range checks, packing state. Plans do not create wear events and can remain as historical plans. |
| Candidate | `purchase_candidates` is separate from garments, with expiry and optional owned confirmed-purchase reference. |
| AI | `ai_jobs`, `outfit_feedback`; operation deduplication, constrained statuses, bounded attempts, lease consistency, usage/model/prompt/pricing/latency fields. `uncertain` represents an ambiguous provider timeout. |
| Consent | `consent_events` is append-only to the backend role, versioned by purpose, with explicit AI recipient. Revocation appends an event. Account cascade still erases these records. |
| Purchases | `subscription_entitlements`, `subscription_events`; server-only writes, unique original transaction/notification IDs, status and environment. One current entitlement per user for the one subscription group; historical notifications remain separate. Apple verification belongs to T048. |
| Usage | `usage_reservations`; one reservation per owned AI job and operation, reserved/settled/refunded lifecycle, positive units and expiry. Settlement/budget transactions belong to T034. |
| Sync | `sync_operations`; owner/operation uniqueness, base/result version, request hash, applied/conflict/deleted outcome. Entity UUID deliberately has no FK: a tombstone must outlive the entity it describes. API validates polymorphic targets. |
| Deletion | `deletion_jobs` survives auth/profile deletion without FK, with one durable owner tombstone. Its trigger serializes creation against owner writes with a transaction advisory lock; subsequent writes are rejected, including through service_role. Backend role cannot delete tombstones. |
| Support/audit | `support_requests` is owner-isolated; `operator_audit` is server-only and append-only, with actor/subject/request identifiers but no arbitrary payload. |

Composite `(user_id, referenced_id)` foreign keys enforce ownership even for
privileged backend writes. UUIDs, timestamps and increasing versions are present
on mutable domain records, including link tables. Updates preserve owner, ID and
creation time and increment version. The API still must match `base_version` in
its UPDATE predicate; a version column alone does not implement conflict handling.
Audit records are immutable events, so have a creation time and no update version.

Indexes cover owner pagination/changes, parent references, active wardrobe,
wear dates, plan/trip dates, ready jobs, leases, consent history, expiries and sync
entity lookup. Primary/unique indexes additionally cover owner/ID, request UUIDs
and deduplication. Search/ranking tuning requires the actual T020 query workload.

## Access boundary and deletion obligations

Every domain table enables and forces RLS. `authenticated` receives SELECT only
with `auth.uid() = user_id` (profile ID for profiles). Missing identity returns no
rows. Anonymous users receive no schema/table access. Operator audit, raw Apple
notifications and deletion jobs are not client-readable. PUBLIC function access
is revoked. `schema_migrations` is an administrative ledger without client access.

All mutations must go through the trusted server. This deliberately prevents
clients from forging entitlements, usage settlements, consent or partial wear
snapshots. The service role bypasses RLS; T009 must authenticate every operation,
validate its owner, perform atomic transactions and return safe DTOs. Never ship
that credential in iOS. Tests exercise both RLS and constraints as separate gates.

Hard database deletion does **not** remove object storage files. T011/T017 must
mark a deletion job, inventory object keys before cascading metadata, remove
objects with retries, then delete auth/profile data. Use ordinary READ COMMITTED
transactions and retry transaction failures; explicit deletion and mutations must
honor the account lock. Keep deletion tombstones through restore/replay windows.
The authorized retention policy for audit subject IDs/tombstones is still to be
specified in T015/T017/T055; administrative erasure must not silently reopen sync.

Multirow wear atomicity/idempotent response replay, prior-estimate conflict
resolution, queue execution, AI consent rechecks, object cleanup, subscription
verification and API authorization are downstream tasks, not claimed here.

## Applying and upgrading

Use an authorized PostgreSQL connection supplied outside the repository (standard
PG* variables, never credentials in command text or committed files). Back up and
verify the target first. With a migration-owner connection:

```sh
# Empty database with real auth prerequisites only:
psql -X -v ON_ERROR_STOP=1 -f backend/migrations/0001_wardrobe.sql
psql -X -v ON_ERROR_STOP=1 -f backend/migrations/0002_product.sql

# Existing v1 database: apply ONLY the second file.
psql -X -v ON_ERROR_STOP=1 -f backend/migrations/0002_product.sql
```

Each file commits its ledger entry in the same transaction as its DDL. Check
`app.schema_migrations` before proceeding; apply exactly once in order with a
single migration operator. Unexpected existing objects or duplicate versions fail
rather than being hidden by `IF NOT EXISTS`. No previous schema existed in the
repository: v1 is the wardrobe foundation, v2 the additive product extension.
This is a tested upgrade path to be executed, not evidence of deployed history.
There is no destructive down migration; recover a failed transaction or apply a
reviewed forward fix. Do not modify applied migration files.

## Verification and current evidence

```sh
node scripts/harness-check.mjs
# Requires PostgreSQL 15+, psql/createdb/dropdb and a disposable superuser cluster:
bash scripts/test-database.sh
```

The runner creates two uniquely named databases and removes only those databases
on exit. It also creates test roles if absent; run on a disposable cluster, never
on staging/production. It ignores PGDATABASE for test database selection.

The fresh path applies both migrations then domain/security assertions. The
upgrade path inserts real v1 prices, dates and wear links, applies v2, checks
preservation, then runs the same assertions. Assertions cover all-table RLS and
grants, owner reads, forbidden direct writes, cross-owner links, request and
reservation uniqueness, money/estimate/date/lease constraints, version updates,
wear snapshot preservation, cascades, immutable consent, deletion tombstones and
stale-write rejection. An additional Linux CI job runs these on PostgreSQL 15;
the existing macOS job remains in place.

**Local evidence:** harness static validation passes; shell syntax passes.
**Not executed:** PostgreSQL tests (no psql/server in sandbox; Docker socket
permission denied). No dependencies were installed. Green harness output is not
proof of SQL execution. Acceptance requires the database CI job to pass on both
paths, followed by verification against real Supabase auth/RLS on the authorized
staging once T007 is resolved. Concurrent deletion/write races and large-data
query performance should additionally be exercised in T012/T017/T058.
