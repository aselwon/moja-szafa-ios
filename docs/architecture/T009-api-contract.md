# T009 — Versioned API foundation

## Implemented surface

`backend/api/openapi-v1.json` is the OpenAPI 3.1 contract. The executable
implementation is migration `003_api.sql`, exposed as PostgREST RPCs in the
existing `app` schema. No additional runtime or dependency is needed.

- `POST /rest/v1/rpc/api_v1_list_garments`: owner-scoped keyset pagination,
  limit 1–100, UUID cursor, ascending immutable ID order, excludes tombstones.
- `POST /rest/v1/rpc/api_v1_save_garment`: create (`base_version: null`) or
  optimistic update (positive `base_version`) of name, category, nullable integer
  price in grosz and availability. Other garment fields are preserved on update;
  their feature forms and endpoints will extend the contract in later tasks.

Both accept `{ "request": ... }` and require a verified user JWT. The RPC
Content-Profile header is `app`. Function names and DTO namespace carry `v1`;
additive optional response fields are compatible, breaking changes require v2.
The client tolerates additive response fields and rejects invalid known values.
Unknown request fields are rejected, especially attempts to supply an owner.
PLN is fixed by the database; prices never use floating point.

The scope is a working API foundation and wardrobe read/write vertical slice.
Image upload/finalization (T011), offline sync/outbox (T012), auth/session lifecycle
(T013), wear events, outfit/trip CRUD, AI jobs, statistics, account deletion/export
and purchases retain their feature tasks. This does not claim those APIs exist.

## Errors and validation

Application responses use HTTP 200 with exactly one of `data` or `error`.
Success includes `request_id`; errors include `code`, `message`, `request_id`.
Codes cover validation, missing identity/account, stale version/unavailable
record, mismatched idempotency payload and generic internal failure. An invisible
record produces the same conflict as a missing one; raw SQL details are never
returned by the functions. A new failed attempt gets a new diagnostic UUID.
The success replay preserves the original diagnostic UUID.

JWT rejection, proxy failures and query cancellation may occur before or outside
SQL and use non-2xx HTTP responses. The Swift client preserves HTTP status and
`X-Request-ID` where supplied rather than pretending these contain an application
error. Transport errors and cancellation propagate unchanged. No silent retries,
request/body/token logging or automatic token refresh is performed.

Swift validates before sending; SQL validates independently before writes.
Category/availability enums, nonblank names up to 200 characters, nonnegative
Int64 grosz, positive versions and bounded pagination are enforced. UUID cursors
are data, never URLs; the client never follows a server-supplied next-page URL.
Pagination is not a snapshot: inserts before the cursor appear on the next reload.
T012 change feeds must use their own synchronization contract.

## Durable mutation identity

The caller creates a `SaveGarment` once for a user intent, including operation UUID,
entity UUID, base version and immutable payload. After an ambiguous timeout, resend
that same value. Codable supports persisting it in the future T012 outbox. Never
create a new operation UUID just because the response was lost. A corrected
payload or resolved version conflict is a new intent with a new operation UUID.

The private `(user_id, operation_id)` primary key serializes concurrent attempts.
The record, canonical JSONB request and original response commit in one database
transaction. Same key/body returns the original response without another write;
same key/different body returns `idempotency_conflict`. Stale versions, tombstones
and ownership mismatches do not change records. Failed writes roll back their
ledger insert. Locks are transaction-scoped and released on rollback/crash.

The replay table is inaccessible to clients and keys do not expire while the
account exists. Account deletion cascades replay data. A profile lock coordinates
writes with deletion, and a deleted profile is rejected before any replay. Stored
requests contain private garment metadata: apply the same backup/access policy
as wardrobe data, never log them. Future retention changes must preserve the
no-duplicate guarantee for delayed operations.

## Integration and external verification

`APIClient` uses async URLSession through an injectable transport and a fresh async
access-token provider. `APIWardrobeRepository` consumes all pages for the existing
wardrobe interface; `AppDependencies.configured(client:)` is the integration entry.
The default `live()` remains explicitly unconfigured: there is no authorized
staging URL or working session provider in this repository. No mock backend is
selected in release. A Supabase gateway additionally needs its public/publishable
key supplied at configuration time via `publicAPIKey`; never supply a service key.
No credential or concrete cloud endpoint is committed.

After T007 authorization, apply migrations, expose `app` via the selected gateway,
refresh its schema cache and verify these RPCs using real authenticated test users.
The migration owner must be a trusted administrator able to run the narrowly
scoped SECURITY DEFINER functions; the functions fix search_path and explicitly
scope every query to auth.uid(). Do not deploy the local test auth shim.

Verification provided in repository:

1. `node scripts/harness-check.mjs`: OpenAPI references, RPC/client surface and
   project wiring (structural only).
2. macOS CI `xcodebuild test`: validation, explicit null encoding, pagination,
   diagnostic IDs, gateway/malformed-response errors, cancellation and the same
   serialized mutation after a simulated commit followed by timeout.
3. `bash backend/tests/run-tests.sh`: fresh install and populated v002 upgrade,
   rollback/checksums, existing security suite, real SQL replay/conflict/ownership/
   tombstone tests; two simultaneous connections and a third post-commit retry
   assert identical responses, exactly one garment and version 1.
4. On staging, deliberately discard the first committed HTTP response and resend
   the saved operation; verify one row and the original result. Confirm expired
   JWT rejection and cross-owner isolation through the actual gateway.

This Linux sandbox has no Xcode/Swift or PostgreSQL tools. The harness check can
run here, but Swift/SQL runtime tests and the staging HTTP fault injection remain
unverified until the existing macOS/PostgreSQL CI jobs and authorized staging run.

## T022 wardrobe read surface

Migration `011_wardrobe_browse.sql` adds `api_v1_browse_wardrobe` and
`api_v1_garment_detail`; request/response schemas are in `backend/api/openapi-v1.json`.
Browse applies owner, archive, category, availability and literal name/brand search
before pagination. Sort supports name ascending/descending and price ascending
(unknown last), with UUID tie-breaking. The UI requests 40 metadata records per
page; the server caps requests at 100. Offsets are not a consistent snapshot:
concurrent inserts/edits may move boundaries. The client deduplicates IDs; pull to
refresh restarts pagination. Local sorting uses the device locale; server sorting
uses the database collation, so their ordering may differ.

Only an image operation UUID is returned. Visible cards request authenticated
T011 thumbnail capabilities, restricted to the same origin and exact variant path.
No storage keys, signed URLs or image bytes are persisted by the feature. Detail
fetches a full normalized photograph only after its explicit toggle is enabled.
The existing image pipeline does not publish a cleaned variant; this change does
not invent one. Detail history reads distinct `worn_on` dates from historical
`wear_event_items`, excluding tombstones, plans and estimated prior wears.

API repositories retain bounded, account-instance-scoped metadata in memory for
previously visited pages/details. Only connection-loss errors can use that cache;
auth, deletion and other errors clear it. Relaunch without a durable offline store
has no API cache. The T012 OfflineStore composition remains durable and refreshes
its metadata snapshot on the first page only. Migration 011 adds optional display
metadata (including image IDs and archive state) to sync records without changing
outbox writes. Older local snapshots remain readable and gain these fields after
sync. Photos are fetched on demand and unavailable while offline; the local-data
banner states that details/photos may be missing. The live composition
remains explicitly unconfigured pending the existing backend provisioning gate.

Verification for T022:

- Run `node scripts/harness-check.mjs` (with the harness Node PATH). This checks
  contracts, source membership, localization and existing offline backend tests;
  it is not an iOS or PostgreSQL runtime test.
- Run existing macOS CI in Debug/Staging/Release, including `WardrobeTests` and
  `ArchitectureTests`. Tests cover 1,000 items, bounded pages/no image fetching,
  filter-before-page, unknown/zero price, stale async responses, page retry,
  offline distinct wear days and foreign image URL rejection.
- Run `bash backend/tests/run-tests.sh` against disposable PostgreSQL 15 databases.
  `wardrobe.sql` checks all 1,000 owner records exactly once, filters, sorting,
  bounded responses, history/undo and cross-account/deleted-account denial.
- With an authorized configured gateway, seed 1,000 synthetic clothes and ready
  T011 images. Inspect requests while opening/scrolling/loading more: 40 metadata
  records per page, only visible thumbnail requests, no original requests until
  toggling the selected full photo. Record memory/network measurements on iPhone.
- Exercise PL/EN, light/dark, largest Dynamic Type and VoiceOver; verify filters,
  navigation back, empty states and retries. Disconnect after visiting pages and
  detail: cached metadata must be labelled, unseen pages must fail explicitly.
  Relaunch a configured T012 store offline and verify its durable basic metadata
  and history. Check a second account cannot see the first account's data.

No deployed gateway, screenshots, physical-device measurement, PostgreSQL runtime
result or macOS build is claimed by the Linux harness result.
