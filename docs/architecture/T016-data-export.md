# T016 — Private data export

## Implemented contract

`POST /rest/v1/rpc/api_v1_request_export` with `{"request":{}}` uses
verified `auth.uid()` and returns the standard `{data:{id,expires_at},request_id}`
envelope. Anonymous requests receive the standard unauthorized error envelope.
The account lock serializes concurrent requests. One active ticket per account
is reused after timeout/reopening; retry does not extend its 15-minute expiry.
After expiry a new request creates a new ID. Tickets contain no payload, token,
public URL or photos; account deletion cascades them. At most one row per account
is retained, including after expiry.

`GET /v1/exports/{id}` requires a verified bearer session for the ticket owner.
Success is `application/gzip`, `Content-Disposition: attachment`, with
`Cache-Control: private, no-store` and `nosniff`. Denied/expired requests return
404 with `code/message/request_id`; IDs do not disclose another account's state.
A failure after streaming starts aborts the connection, not a successful partial
archive. Clients must discard failed downloads. Redirects are rejected by iOS.

The TAR.GZ contains `data.json` (schema version 1) and `photos/<image UUID>.<ext>`.
Prices are decimal integer strings (or null), preserving PostgreSQL bigint
precision across JavaScript and third-party JSON readers; no float conversion.
JSON includes profile, garments (nullable PLN grosz prices and wear estimates),
outfits/items, historical wear events/items with original dates/timezones,
preferences, feedback, plans, trips/packing, consent choices and purchase candidate
metadata. Photo entries map garment, variant and archive path. Only ready photos
of live, owned garments are included, including archived garments. Pending/failed
uploads and unsynced local drafts are not server photos. The current T011 adapter
stores normalized original/thumbnail JPEGs; it does not yet produce cleaned images
or store purchase-candidate images. Future image storage adapters must support
those formats before those features ship.

SQL explicitly allowlists columns and filters every collection by owner and live
record. No auth records, credentials, transaction/provider payloads, storage keys,
operator audit, job leases or signed URLs enter the archive. An internal snapshot
contains storage keys solely to read photos; the JSON writer removes them.
Unknown future columns do not automatically enter exports.

## Consistency and retention

The JSON collections use one SQL statement snapshot **at download time**, not at
request time. Repeat downloads can reflect later edits. Photos are checked for
ownership, live garment/account and exact key before and after each storage read;
expiry is also checked before completing the archive. Missing/deleted photos fail
the download rather than silently produce a supposedly complete export. A user
can request/retry after synchronizing or resolving pending uploads.

The server streams tar/gzip with backpressure and holds at most JSON plus one
photo, without creating archive files or retaining exported payloads. Consequently
there is no expired archive to clean up. A download already delivered to the user
cannot be revoked. The UI explains this distinction and the need to sync offline
changes first. iOS downloads to a file, uses complete file protection, deletes its
copy when leaving the screen, and purges crash leftovers before showing an account
at the next launch. User-saved/shared copies remain under user control.

## Deployment and verification still required

No service was deployed. `AppDependencies.live()` remains intentionally unconfigured
as in the existing architecture. On an authorized backend:

1. Apply migration 009 using the existing migration runner. Run
   `bash backend/tests/run-tests.sh` on PostgreSQL 15; CI runs this suite including
   `exports.sql` for fresh install and populated upgrade.
2. Mount `exportHandler(new DataExport({store: postgresExports(), storage:
   privateFiles(privateImageVolume)}), verifiedAuthenticator)` from
   `backend/exports/export.mjs` on the same HTTPS origin as RPC. Use existing private
   image storage and libpq service credentials, never client-supplied identity.
3. Enforce per-account request/concurrent download limits and HTTP timeouts at the
   gateway; disable proxy buffering and sensitive request/response logging. This
   adapter is not a standalone public server. No new dependencies are required.
4. Run macOS CI build/XCTest. On an iPhone, sign in, export from Profile, save/open
   the archive in Files, verify JSON, prices, historical dates, plans and photos.
   Test PL/EN, large text, VoiceOver, offline/retry, session expiry, logout during
   download and archive removal. Download completion never shares automatically.
5. With two real accounts verify cross-owner denial, ticket expiry after 15 minutes,
   deletion during download and revoked sessions. Exercise 1000 garments/5 years
   of history; measure memory/time under the chosen gateway limits. SQL JSON output
   is bounded to 32 MiB by the adapter; exceeding it fails explicitly. Streaming
   many photos performs lightweight authorization queries and needs load validation.

Local harness covers archive extraction with Python tarfile, fields/photos, safe
paths, ownership denial, expiry/deletion before and during reads, missing photos
and private error envelopes. SQL tests cover real ownership filters, ticket replay,
expiry/renewal, historical/plan inclusion and grants. Swift tests cover ticket
recovery/decoding and temporary-file cleanup. Linux harness success is not evidence
of SQL execution, an iOS build, or staging integration.
