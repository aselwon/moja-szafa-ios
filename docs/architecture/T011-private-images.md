# T011 — Private image pipeline

## Implemented repository boundary

`backend/images/pipeline.mjs` implements signed uploads/downloads, private file
storage, decoding and orphan cleanup. `http.mjs` provides a Node HTTP handler;
`postgresImages()` uses the existing PostgreSQL/libpq credential mechanism.
Migration 008 adds the durable upload ledger and service-only transactional
commands. There is no mock default, public bucket, external API call or deployment.
The file adapter requires a **private persistent POSIX volume**, shared by the
HTTP service and cleanup worker. It is an adapter for backend operation, not a
replacement of PostgreSQL as the metadata source of truth. The proposed managed
storage provider from T007 is not configured; its eventual adapter must preserve
these access and lifecycle semantics. Ephemeral serverless disks are unsuitable.

## HTTP contract and composition

Construct `ImagePipeline` with `postgresImages()`, `privateFiles(volumePath)` and
a server-only random signing key of at least 32 bytes supplied by the deployment's
secret manager. Mount `imageHandler(pipeline, authenticate)` on a Node server.
`authenticate(authorizationHeader)` must return the owner UUID **after real JWT
and session verification**, including issuer/audience, expiry and deletion.
Missing authentication/configuration must fail closed. Never derive identity from
request JSON. The module intentionally does not invent a production Auth setup.

| Request | Response |
| --- | --- |
| POST `/v1/images/uploads`, JSON `garment_id`, `operation_id` UUIDs | `image_id`, relative `upload_url`, `expires_in`, `max_bytes`, `content_types` |
| PUT returned `upload_url`, raw image bytes | `image_id` after both normalized variants commit |
| POST `/v1/images/{image_id}/{original\|thumbnail}/url` | relative `url`, `expires_in` |
| GET returned URL | JPEG, `private, no-store`, `nosniff` |

All four routes require an authenticated session, including signed URLs. Signatures
bind owner, operation, action/variant and a 60-second expiry; expiry is exclusive.
Paths must match the signed operation. Tokens are never stored in PostgreSQL.
Errors use `code/message/request_id`; nonexistent and foreign objects share the
same denial. HTTP 413 covers size, 422 decoding, 403 authorization, 503 storage.
Disable query-string/header/body logging at the gateway, TLS terminate only at a
trusted ingress, enforce upload body deadlines and concurrency/account rate limits.
Do not cache responses or expose the volume through static hosting. Signing-key
rotation invalidates outstanding links. A signed link is not a bearer substitute
for session authentication; the recipient must also be the live owner.

## Validation and persistence

The body is bounded to 12 MiB while streaming, before decoding. Pillow runs in a
separate process with a 15-second deadline. Accepted inputs are single-frame
JPEG/PNG/WebP, at most 24 million pixels and 12,000 pixels on an axis. MIME supplied
by a client is not trusted. The decoder verifies structure and fully decodes pixels,
applies EXIF orientation, flattens transparency on white, and encodes a fresh RGB
JPEG (long side <=4096) plus a thumbnail (<=320). Fresh canvases exclude EXIF/GPS,
comments and ICC data. Neither original upload bytes nor their metadata are saved.
“Original” means the normalized unsegmented photograph, not the camera file.
HEIC must be converted on-device before this endpoint; a server HEIC codec is not
bundled and unsupported formats fail explicitly. No image is sent to AI here.

Install `backend/images/requirements.txt` when provisioning a permitted environment;
no package was installed in the sandbox (Pillow 10.2.0 was already available).
CI provisions Python/Pillow. Resolve and security-review a fixed decoder version
for the deployment image; this repository currently specifies a compatible range.
Run the decoder under OS memory/process limits in production as well as application
pixel/time limits. Resource exhaustion must not take down the gateway.

Prepare is owner-scoped and idempotent by operation UUID (15-minute admission
window). Claim gives a single 60-second processing lease and fence. Concurrent
requests cannot overwrite a live attempt. Files are flushed before the fenced
transaction publishes both variants. Retrying after a lost committed response
returns success without writing again. Parent records are locked and checked live
at publication. One original/thumbnail pair per garment follows the existing schema;
replacing an existing pair is not implicitly authorized by a new upload.

A failed or interrupted processing attempt is not automatically decoded again.
Poll/retry the same request after a lost success response; if it did not commit,
wait for cleanup and start a new operation. This avoids stale writers overwriting
new attempts. No AI usage reservation is created or charged for image normalization.

## Durable cleanup

Run `node backend/images/cleanup.mjs /absolute/private/volume` under a supervisor.
It polls every ten seconds and drains full batches immediately. Alternatively,
run `await pipeline.sweep()` from a supervised worker at least once a minute,
repeating while batches of 100 remain. Errors must be retried with bounded backoff
and an operational alarm. Sweep first retires expired drafts/leases, deleted
accounts/garments and missing image references in PostgreSQL. Retired operations
cannot publish or be read. It then deletes both deterministic keys idempotently,
and acknowledges only after both removals. If storage or acknowledgement fails,
the next sweep retries the same keys. The ledger has no owner FK and survives
account cascades. Tombstones are retained and revisited hourly, catching late
writes and objects reintroduced by restore; do not purge them without a coordinated
storage/backup retention policy. Empty directories contain no personal bytes.
Cleanup is separate from the AI job queue because it needs no consent or AI quota.
The private ledger itself is the durable work queue, not an in-memory timer.

## Verification and outstanding integration

- `node scripts/harness-check.mjs`: real decoder/metadata/orientation/thumbnail
  tests, file adapter, signed capability expiry at the boundary, identity mismatch,
  revocation, action/variant confusion, replay and idempotent deletion. Service
  tests use an explicit metadata test double; they are not PostgreSQL evidence.
- `bash backend/tests/run-tests.sh`: migration 008, owner isolation, publication
  fences, duplicate claim/replay, cascading deletion and surviving cleanup work.
  Requires PostgreSQL 15; unavailable in this Linux sandbox. Require the existing
  `postgres` CI job to pass, including upgrade/parity and rollback checks.
- Require existing macOS build/test jobs to pass; no iOS source changed here.
- After authorized T007 provisioning, wire real Auth, persistent private storage
  and the scheduled sweep worker. With two accounts, upload a photo containing
  GPS/EXIF, inspect both downloaded JPEGs, reject anonymous/cross-account requests
  and replay each URL at/after expiry. Restart between writes and finalize, and
  between each removal and acknowledgement; verify eventual removal after lease
  expiry and account deletion. Attempt direct filesystem/storage URLs and ensure
  they are unreachable. Restore storage and demonstrate tombstone reapplication.

No deployed endpoint, live storage ACL check, PostgreSQL execution or macOS build
is claimed by local unit tests. Both acceptance criteria still require this
integration evidence before being marked fully met.
