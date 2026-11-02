# T016 — Private data export

Implemented locally; deployment and device acceptance remain unverified.

## Contract and contents

`backend/api/exports-v1.json` defines the authenticated gateway endpoints. The
verified session subject is the sole source of owner identity. POST with an
operation UUID creates a database snapshot, returning its ID and absolute expiry.
Retries reuse that UUID. At most one unexpired snapshot exists per owner; a new
UUID during that interval returns the existing receipt, including after app restart.
GET downloads a gzip-compressed POSIX TAR containing `data.json` and JPEGs under
`photos/<image metadata UUID>.jpg`. JSON image records point to those archive paths.
No bearer capability is exposed in a URL. Another account cannot use the export ID.

The version 1 JSON uses explicit column projections: profile, garments including
integer grosz prices and initial wear estimates, image metadata, outfits and their
items, historical wear events and their independent item lists, preferences,
feedback, planned outfits, trips/checklists and purchase-candidate metadata.
Archived garments are included; tombstoned records are excluded. Original and
thumbnail images currently supported by T011 are included. A missing, deleted or
unsupported image fails the whole download; it never silently produces a partial
archive. Future cleaned/candidate image storage needs an adapter before it can be
exported. Auth records, credentials, storage keys, worker payloads, operator audit,
signed URLs and other owners' records are not exported. Future fields are excluded
unless explicitly added to the projection and reviewed.

This is a server snapshot. Local-only onboarding preferences and unsynchronized
offline drafts are not included. The UI instructs users to synchronize first.
Snapshots remain unchanged during their lifetime, including after price edits.

## Lifetime and operations

Snapshots expire **24 hours after request**, without extension on retry. Every
read checks owner, live profile and database time; these checks run again after
archive assembly. Image access uses the T011 checks. The gateway revalidates the
session after assembly. Responses use `private, no-store`. The archive exists only
in process memory and is never published to a static bucket or public web root.
Downloaded copies explicitly saved by the user do not expire.

Mount `exportHandler` alongside the T011 gateway behind TLS, with its existing
verified session authenticator. Construct `ExportService` with `postgresExports()`
and the production `ImagePipeline`. iOS uses the configured API origin for
`/v1/exports`, so the reverse proxy must route these paths on that same origin.
The database function is executable only by service_role; it must not be exposed
as a user-callable PostgREST RPC. Apply migration 009 with the migration runner.

Schedule `node backend/exports/cleanup.mjs` every minute with the existing private
libpq environment, and alert on a nonzero exit. Cleanup deletes expired snapshots
and those belonging to soft-deleted profiles; hard deletion cascades immediately.
Restart/retry is safe. Expiry blocks reads even if cleanup is delayed. Restored
backups must have account deletions reapplied and cleanup run before traffic.
Never log JSON bodies, archives, Authorization headers or database command input.

Use per-account request/concurrency limits and a bounded global download pool.
The current in-memory assembler refuses archives above 256 MiB uncompressed;
large wardrobes need a streaming adapter before production scale acceptance.
The database adapter also caps JSON at 32 MiB. No truncation is permitted. A failed
read can be retried within the original expiry; after expiry request a new export.

## Verification and remaining gates

- `node scripts/harness-check.mjs`: archive layout/checksum, prices/history/plans,
  ownership denial, expiry/account deletion during image reads, missing image
  failure, no-store headers and session revocation. Also existing repository checks.
- `bash backend/tests/run-tests.sh` on PostgreSQL 15: migration/upgrade plus
  `exports.sql` covering owner-scoped projections, immutable snapshots, idempotent
  requests, expiry, cleanup and service-only access.
- macOS CI builds/tests the native PL/EN profile flow and authenticated client tests.
- On staging and a physical iPhone: sign in with two accounts, request/export/save
  to Files, unpack TAR.GZ, compare all history, plans, prices and photo bytes; retry
  after disconnect/relaunch, verify foreign IDs and expired sessions are denied,
  advance test expiry, delete account and verify denial plus cleanup. Check large
  text, VoiceOver, cancellation and saving errors. Verify archive memory usage at
  the size limit and configure gateway rate limits before rollout.

This Linux sandbox has no PostgreSQL client, Xcode or configured staging/session
credentials. No database execution, Apple-device test or deployment is claimed.
