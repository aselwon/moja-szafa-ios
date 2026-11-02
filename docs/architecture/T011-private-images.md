# T011 — Private image pipeline

## Delivered and deployment boundary

The repository now contains a server-side pipeline, authenticated HTTP handler,
PostgreSQL inventory, private-volume storage adapter, cleanup command and a real
Swift/ImageIO decoder. No services have been deployed. T007 still has no approved,
configured provider. There is no default mock, default signing key, public bucket,
unauthenticated server listener or new package dependency.

The implemented codec requires **macOS** with Swift, ImageIO and CoreGraphics.
This is a concrete runnable codec for the existing macOS runner, not a claim that
Supabase Edge Functions can run ImageIO. Before staging, approve a macOS worker
host/private durable volume or supply an equivalent sandboxed decoder and private
Storage adapter on the approved worker platform. Linux decoding is currently
blocked by unavailable dependencies; none were downloaded. Do not deploy a stub
codec. The iOS app is unchanged; connecting its photo-import UI is later work.

## Composition and HTTP contract

Build with `swiftc backend/images/ImageDecoder.swift -o /approved/path/image-decoder`.
Compose `ImagePipeline` from `postgresImageLedger()`, `privateFiles(absolutePath)`,
`imageIODecoder(executablePath)` and at least 32 random secret bytes supplied by the
server secret manager. Rotation invalidates old tokens. The secret never reaches
iOS, command arguments, logs or the repository. Pass that pipeline and a real
Auth verifier to `imageHandler`. Mount behind HTTPS with a request/concurrency
limit, maximum body size of 20 MiB, a 30-second body deadline and disabled URL/body
logging. The verifier must check issuer, audience, signature, expiry and account
revocation. Never read owner identity from client JSON or an unverified JWT.
The database service connection uses libpq secure service configuration.

Every endpoint requires authentication. Success JSON is `{data, request_id}`;
failures are HTTP 400 with `{error: {code, message, request_id}}`. Error detail is
intentionally generic to avoid disclosing object existence. The gateway may
reject authentication earlier with 401. Objects and errors use `private, no-store`.

| Endpoint | Input | Success |
| --- | --- | --- |
| POST `/v1/images/begin` | JSON `garment_id`, `operation_id` (UUIDs) | `id`, upload `token`, `expires_in: 300` |
| POST `/v1/images/upload?token=…` | Raw image bytes, not multipart; declared MIME is not trusted | `id` after both variants commit |
| POST `/v1/images/read-token` | JSON `id`, `variant` (`original` or `thumbnail`) | `token`, `expires_in: 60` |
| GET `/v1/images/read?variant=…&token=…` | Signed token plus authenticated owner | PNG bytes |

Tokens sign owner, upload ID, operation/variant and expiry with HMAC-SHA256.
They are identity-bound gateway URLs, not transferable storage bearer URLs.
Expiry is exclusive; reads always recheck live account, garment and image rows.
Even an unexpired leaked token fails for another identity. Physical files have no
public route. The storage root must be a dedicated service-owned volume with no
untrusted filesystem writers/symlinks and must never be served by a static server
or CDN. Direct object keys do not grant access.

## Validation and lifecycle

Input: 1 byte–20 MiB, JPEG/PNG/HEIC/WebP as identified by ImageIO, exactly one frame,
maximum side 12,000 pixels and 40 million pixels total. Headers are inspected
before decoding; truncated/undecodable sources fail. The codec applies orientation
and redraws decoded pixels into a fresh sRGB bitmap, retaining alpha but copying
no source EXIF/GPS/IPTC/XMP. Both outputs are PNG: normalized original up to 4096
pixels, thumbnail up to 384. Each output is limited to 20 MiB. “Original” denotes
the normalized photo, not a retained camera file. RAW, animated images and
multi-image HEIF containers are rejected; users can supply a single still image.
The codec subprocess has a 30-second timeout and bounded output; production must
also enforce OS memory/concurrency limits. Raw input stays in request/subprocess
memory and is never stored by the pipeline.

Migration 007 adds a private inventory surviving account/garment cascade deletion.
Begin checks ownership and records both deterministic object keys before writing.
The operation UUID deduplicates begin; a different garment is a conflict. First
upload binds a SHA-256 digest, so retries cannot mix different source photos.
Writes publish complete files atomically, without overwrite. Finalization creates
both image rows in one transaction; lost responses can be retried. Pending
sessions expire after 10 minutes and cannot be revived by issuing a fresh token.
Create a new operation after expiry. Existing garment image variants cause a
conflict rather than an implicit replacement; image replacement needs an explicit
higher-level delete/replace flow.

No external AI or usage reservation is involved. Image validation is synchronous
within the upload request, with a durable inventory for crash recovery; it does
not misuse T010's AI job queue or consume AI limits. A failed upload can be retried
with the same bytes/token before expiry; status survives gateway restarts in SQL.

## Orphan cleanup and recovery

Run `node backend/images/sweep.mjs /absolute/private/volume` every minute under the
worker service identity. One invocation processes at most 100 tombstones, ordered
by last sweep, without starving newly abandoned sessions. Monitor nonzero exit,
oldest expired pending session and cleanup backlog; increase schedule capacity as
needed. Expired uploads, deleted accounts/garments and removed image relationships
become permanently unreadable tombstones. Delete both objects and any interrupted
atomic-write temporary files. Missing files count as success; other storage
errors keep the row eligible for retry. Inventory is never removed by cleanup:
repeat sweeps repair partial deletion and late writes after a lease/expiry race.
This deliberately trades retained opaque inventory for recoverability; retention
compaction requires a proven maximum late-writer horizon and separate review.

Use one shared durable volume for all instances of this adapter. Disk persistence
and backup are deployment requirements, not properties of a Node process.
Reapply deletion tombstones after database/storage restore before serving reads.
Storage-service adapters must preserve immutable writes and idempotent deletion.
No storage API was called in this task.

## Verification and remaining acceptance evidence

- `node scripts/harness-check.mjs`: runs signature/expiry/identity, input rejection,
  replay, revocation, repeated cleanup and real private-file tests. Ledger/decoder
  doubles isolate orchestration; these do **not** establish real codec/SQL behavior.
- `bash backend/tests/run-tests.sh`: PostgreSQL 15 clean install/upgrade plus new
  ownership, direct-role denial, pending reads, expiry, digest conflict, atomic
  publish/replay and inventory survival tests. Missing `psql` blocks local execution.
- `bash backend/tests/image-codec.sh`: real ImageIO fixture decode, EXIF/GPS removal,
  orientation, thumbnail sizes, truncated data, unsupported multi-frame data and
  dimension bounds. Added to existing macOS CI. Missing `swiftc` blocks execution
  in this Linux sandbox. macOS CI still needs an actual green run.
- Authorized staging must mount the handler with real JWT verification and private
  storage, run owner A/B/anonymous HTTP tests, test upload and read expiry, probe a
  direct object URL, kill the process between object writes and database commit,
  retry after restart, expire an abandoned upload, delete an account, and verify
  bytes are removed by the scheduled sweeper. Repeat with camera HEIC/PNG/JPEG,
  corrupted images and large files; inspect output metadata and thumbnails.

Both product acceptance criteria need this staging evidence; passing local
orchestration tests alone is not a claim of deployed storage isolation.
