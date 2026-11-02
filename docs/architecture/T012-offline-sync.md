# T012 — Offline synchronization

## Implemented boundary

`OfflineStore` is the account-scoped actor used by
`AppDependencies.configured(client:accountID:storageDirectory:)`. The caller must
supply a client whose token provider belongs to that authenticated account and
retain one store per account/database URL. The snapshot also verifies account
identity before applying remote data. `live()` still fails explicitly until
real environment/auth configuration is supplied; T012 does not invent a backend.

SQLite persists a versioned local snapshot (garments, historical wear items,
tombstones) and UUID outbox in one transaction, with FULL synchronization. JSON
inside the SQLite row is the local serialization, not a second source of truth.
A failed write leaves actor memory unchanged. Invalid/corrupt/unknown-format
stores fail closed instead of silently recreating and losing queued writes.
The database is excluded from backup and uses iOS file protection. No tokens or
images are persisted here. One-row storage deliberately favors transactional
correctness; large-library profiling and normalized local tables may be needed
before the 1,000-garment / five-year release performance gate.

## Integration and conflict behavior

- `saveGarment` and `recordWear` commit locally without network access. Local
  unsent garment edits coalesce. Once an operation might have reached the server,
  its UUID and payload are frozen: another edit returns `pendingChange` until
  acknowledgement or conflict resolution. This avoids changing an ambiguous write.
- Wardrobe reads trigger one reconciliation pass and fall back to local data on
  synchronization failures; cancellation, storage failure and account deletion
  remain errors. `status()` exposes durable failures/retry dates for feature UI.
  `dependencies.offline` exposes mutations and explicit `synchronize()` for the
  foreground/reconnect/retry hooks of future feature flows. No background execution
  entitlement or always-running timer is assumed.
- Pull before and after writes. The full snapshot includes tombstones and is built
  in one SQL statement; it cannot skip a transaction as timestamp cursors can.
  Tombstones must be retained for the account lifetime. Do not physically purge
  individual records until the sync protocol supports deletion compaction.
- Pending local fields survive a remote edit. Server `base_version` rejection is
  durable. `resolveGarment(keepLocal:)` fetches current state; accepting remote
  removes the intent, keeping local creates a new UUID at the fetched version.
  Tombstones hide the garment immediately and cannot be overridden.
- Transient failures use persisted exponential delay, capped at one hour. Each
  invocation makes at most one attempt per queued operation, without sleeping;
  foreground/reconnect/manual retry invokes another pass. Validation/idempotency
  errors require intervention; conflicts do not silently overwrite server data.
- Wear writes wait for pending garment writes, snapshot their garment IDs, retain
  the original DATE/timezone, reject future days and count unique local days.
  Independent events merge; no AI or current outfit membership determines history.
- Account deletion must call `invalidateAccount()` immediately on the active
  store; this durably erases local rows/outbox and fences in-flight results.
  Remote `account_unavailable` does the same. PostgreSQL checks/locks the profile
  before mutations **and replay**, so delayed writes cannot revive a deleted
  account. Full deletion workflow and auth logout/cache lifecycle remain T016/T013.
  Dispose the old account's store/client on logout; never reuse them for another
  account. The deleted database marker must not be reset for that identity.

## API and migrations

Migration 004 adds `api_v1_save_wear` and `api_v1_sync_snapshot`; OpenAPI describes
both RPCs. Bearer identity is server-derived, including all join rows. Wear events,
items and replay response commit atomically in the existing private replay ledger.
Profile and garment locks serialize mutations with deletion; same-key retries
reuse the original response. Existing migrations and their checksums are unchanged.

## Verification

- `node scripts/harness-check.mjs`: structural checks, contract references,
  environment guards and secret scanning (not compilation).
- macOS: run the existing CI Xcode Debug/Staging/Release test matrix, including
  `OfflineStoreTests` (SQLite restart, coalescing, timeout replay, conflict,
  tombstone, account deletion, validation and calendar-day counting).
- PostgreSQL 15: `bash backend/tests/run-tests.sh` includes migration 004 on fresh
  and populated upgraded databases, plus `offline-sync.sql`: replay, owner
  isolation, atomic rejected writes, local dates, tombstones and deletion fencing.
- Device/staging: authenticate two devices as one account; add/edit and record
  two wears of one garment on one day in airplane mode; terminate/reopen, reconnect
  and confirm one garment and one counted day. Edit on both devices and explicitly
  resolve; delete the account while the other device has queued writes and confirm
  its local data clears and no server rows are recreated. Inspect no private data
  in logs. Requires real auth/backend configuration and devices.

The Linux sandbox has no Xcode/Swift or PostgreSQL executables. Runtime tests and
real-device synchronization are not claimed as passed here. No network resources,
accounts, secrets or deployment were changed.
