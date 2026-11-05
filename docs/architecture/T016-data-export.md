# T016 — Private data export

Repository implementation; no production deployment or real-account/device
acceptance is claimed. The current client composition is configuration-gated:
missing or unsafe public gateway configuration returns an unconfigured wardrobe
repository. Gateway export requests require a verified current session.

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
validated MIME type. The gateway's private image adapter stores `original.jpg`,
`thumbnail.jpg` and (when present) `cleaned.png` in its private volume; export
reads use the authorized storage adapter. The archive contains no storage keys,
auth tables, session credentials, operator audit, worker leases, provider
configuration or billing transaction identifiers. New database columns are not
automatically exported.

This is an export of synchronized server data. Device-local T014 preferences,
unsynced outbox changes/drafts and temporary purchase-candidate image objects are
not currently part of the archive; the UI explicitly describes local data scope.
The gateway's private filesystem adapter supplies normalized original/thumbnail
JPEGs and optional cleaned PNGs through the trusted `get(key)` interface.

## Runtime integration and retention

Migration 009 provides the export ledger. The HTTP gateway binds export commands
to the authenticated request context and applies its 512 MiB archive cap:

```js
const exports = storage && exportDirectory
  ? exportHandler(new DataExports({
      store: commands('exports'), storage, directory: exportDirectory,
      maxBytes: 512 * 1024 ** 2,
    }), authenticate)
  : null;
```

The gateway passes the bearer session token to Managed Auth's
`/get-session?disableCookieCache=true` endpoint. It validates the returned
session/user IDs, verified email, non-banned/non-impersonated state and expiry,
then binds that session to the database request context. It does not locally
verify JWT signatures or issuer/audience claims. Its database login must be a
least-privilege member of `szafa_gateway`, never `service_role` or the owner. The
public gateway does not read the export ledger directly. The updated
`backend/deploy/neon-bootstrap.sql` grants it only the no-argument
`gateway_private.prune_exports()` maintenance function; that fixed-action
SECURITY DEFINER wrapper can purge expired export snapshots but accepts no owner,
path or arbitrary command. The bootstrap grant and this runtime version are not
deployed yet.

The gateway starts export retention on startup, then waits 60 seconds after each
sweep completes before scheduling the next one. Runs do not overlap, and shutdown
waits for an in-flight sweep. The sweep uses the same private spool as the HTTP
export service: expired or soft-deleted-account snapshot payloads are nulled;
operation UUIDs remain to prevent replay from renewing expiry. Hard account
deletion cascades the ledger. Successful/error transfers erase spools; the sweep
removes crash-left spools after 15 minutes. Database/API expiry is enforced even
if cleanup is unavailable. Apply the updated bootstrap grants and deploy the
gateway runtime before relying on scheduled retention.

`backend/exports/cleanup.mjs PRIVATE_EXPORT_SPOOL` remains a standalone
alternative for environments that do not use gateway-managed retention. Do not
run it alongside the gateway scheduler against the same spool/database. The
spool must be a dedicated private volume outside web roots, with enough disk
space and monitoring; archive directories/files use 0700/0600. This code permits
two archive builders per process and one per account. `DataExports` has a 20 GiB
library default, but the current HTTP gateway explicitly enforces a 512 MiB
per-archive cap; metadata reads are bounded at 64 MiB. Limits fail explicitly,
never truncate successful exports. Validate capacity with the 1000-garment
fixture before production; use an approved larger gateway cap if required.
Backups follow the backend's separately approved retention policy.

## Verification and remaining gates

- `node scripts/harness-check.mjs`: passed 89/89 checks in the current checkout,
  including archive behavior and the two export-retention scheduler tests.
- `PGHOST=127.0.0.1 PGPORT=<disposable-local-port> PGUSER=postgres
  GATEWAY_PG_TESTS=1 node --test backend/gateway/postgres.test.mjs`: passed 1/1
  against a disposable local PostgreSQL 15 container. This exercises gateway
  bootstrap, owner isolation, replay, session revocation and deletion guards;
  it does not deploy the bootstrap or gateway runtime.
- The full SQL lifecycle suite and native `DataExportTests` were not rerun for
  this retention change. CI must compile Debug/Staging/Release and run the native
  export tests before merge.
- Authorized staging/iPhone check: request from account A, save to Files, extract
  TAR, compare JSON and photo bytes against fixtures including prices/history/
  future plans. Try A's UUID as B and unauthenticated; verify no payload. Retry
  after 15 minutes, revoke session/account while building, interrupt download,
  restart app/worker, and check cache/spool cleanup. Test offline retry, large
  text, VoiceOver, long download/backgrounding and device free-space errors.

Full end-to-end acceptance remains **needs verification** until these real
infrastructure and device checks pass; harness success alone is not release proof.
