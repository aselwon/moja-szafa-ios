# T016 — Private data export

Repository implementation; no backend deployment or real-account verification is
claimed. T007 gateway/storage provisioning and T013 device authentication remain
external prerequisites. `AppDependencies.live()` still fails closed.

## User flow and contract

Profile → Export data → Request export → Download archive → Save/share.
PL/EN copy explains the 15-minute window, server-synchronized scope, offline retry
and that user-saved copies do not expire. Navigation back cancels pending work
and removes the app's downloaded copy. The expiry timer removes it too; next
app launch removes crash-left downloads. Files use complete data protection and
an ephemeral, uncached URLSession; redirects are rejected. Downloads use disk,
not a multi-gigabyte Data allocation. A delayed result after navigation is erased.

Mount these routes on the **same HTTPS origin** configured for APIClient:

| Method and path | Input | Success |
| --- | --- | --- |
| `POST /v1/exports/{operation_uuid}` | Current bearer session, no body | `{ "id": "UUID", "expires_at": "ISO8601 timestamp" }` |
| `GET /v1/exports/{operation_uuid}/archive` | Same authenticated owner | `application/x-tar`, attachment `moja-szafa.tar` |

An operation UUID is an idempotency identifier, **not** a download capability.
Neither endpoint accepts an owner, arbitrary path or redirect URL from the client.
Both require a verified current session. There are no public or signed bearer
URLs. Cache-Control is `private, no-store`; errors contain only
`code/message/request_id`. Missing session is 401; unknown/cross-owner/expired
requests use the same generic 503; oversized archives use 413. A lost POST
response can be retried with the same UUID without extending expiry. One live
request per account is permitted. The current view keeps its UUID through
retries; reopening the view creates a new intent and may require waiting for the
previous 15-minute window to end.

The request stores one consistent PostgreSQL JSON snapshot. Archive retries use
that snapshot and current image bytes, with ownership/readiness checked before
and after each storage read. A missing or deleted photo fails the entire archive;
it is never silently omitted. Final account/session/expiry checks precede delivery.
The transfer is interrupted at expiry. Already downloaded bytes or deliberately
saved copies cannot be revoked.

`data.json` schema version 1 contains explicit field allowlists for profile,
garments (including archived garments), outfits and items, historical wear events
and their original items, preferences, feedback, consent, plans, trips and packing,
purchase-candidate metadata, entitlement summaries and support requests. Prices
are nullable **decimal integer strings in grosz**, preserving the full PostgreSQL
bigint range; currency stays PLN. Local dates, estimated prior wears and tracking
boundary remain unchanged. Plans never become wear events. Empty tables are `[]`.
Ready garment photos include original, cleaned and thumbnail variants when
present. Each image has `archive_path` under `photos/`, based on its UUID and
validated MIME type. The archive contains no storage keys, auth tables, session
credentials, operator audit, worker leases, provider configuration or billing
transaction identifiers. New database columns are not automatically exported.

This is an export of synchronized server data. Device-local T014 preferences,
unsynced outbox changes/drafts and temporary purchase-candidate image objects are
not currently part of the archive; the UI explicitly describes local data scope.
The existing T011 filesystem adapter supplies normalized original/thumbnail JPEGs;
future cleaned-image storage must provide the same trusted `get(key)` interface.

## Runtime integration and retention

Apply migration 009 through `backend/migrate.sh`; historical migrations are
unchanged. `app.exports_command` is executable only by service_role. Do not expose
it directly to app roles. The HTTP runtime composes:

```js
const service = new DataExports({
  store: postgresExports(),
  storage: privateFiles(privateImageDirectory),
  directory: privateExportSpool
});
const handler = exportHandler(service, verifyCurrentSession);
```

Use the existing T011 adapters and verified T013 gateway authenticator. The
runtime must verify JWT signature, issuer, audience, expiry and revoked/deleted
sessions. Credentials come from existing secure libpq configuration, never argv,
source or logs. The spool must be a dedicated private volume outside web roots,
with enough disk space and monitoring; archive directories/files use 0700/0600.
Deployments with multiple service processes need gateway-wide concurrency limits.
This implementation permits two archive builders per process and one per account.
Default archive budget is 20 GiB; metadata reads are bounded at 64 MiB. Limits
fail explicitly, never truncate successful exports. Validate capacity with the
1000-garment fixture before production; use an approved larger budget if required.

Run `backend/exports/cleanup.mjs PRIVATE_EXPORT_SPOOL` under supervision with the
same database and spool as HTTP. It sweeps every 10 seconds, including startup.
Expired or soft-deleted-account snapshot payloads are nulled; operation UUIDs
remain to prevent replay from renewing expiry. Hard account deletion cascades the
ledger. Successful/error transfers erase spools; the sweeper removes crash-left
spools after 15 minutes. Database/API expiry is enforced even if cleanup is down.
Alert on `export_cleanup_unavailable`; rerun cleanup after restore before serving
traffic. Backups follow the backend's separately approved retention policy.
No background provider, paid API, network installation or cloud changes are needed.

## Verification and remaining gates

- `export PATH=/home/harness/.local/bin:$PATH && node scripts/harness-check.mjs`:
  archive read by Python's independent tar reader; exact large prices, photos,
  history/plans, foreign-owner denial, expiry (including during IO), revocation,
  missing storage, limits, cleanup and generic HTTP errors.
- `bash backend/tests/run-tests.sh` on PostgreSQL 15: fresh/upgrade migration,
  snapshot consistency, idempotent expiry, two-owner isolation, field exclusions,
  image authorization, deletion and cleanup, client-role privilege denial.
  Included in the existing CI postgres job. No PostgreSQL binaries in this sandbox.
- Existing macOS CI must compile Debug/Staging/Release and run DataExportTests
  (timeout replay, no false success, cleanup). No Xcode/Swift SDK in this sandbox.
- Authorized staging/iPhone check: request from account A, save to Files, extract
  TAR, compare JSON and photo bytes against fixtures including prices/history/
  future plans. Try A's UUID as B and unauthenticated; verify no payload. Retry
  after 15 minutes, revoke session/account while building, interrupt download,
  restart app/worker, and check cache/spool cleanup. Test offline retry, large
  text, VoiceOver, long download/backgrounding and device free-space errors.

Full end-to-end acceptance remains **needs verification** until these real
infrastructure and device checks pass; harness success alone is not release proof.
