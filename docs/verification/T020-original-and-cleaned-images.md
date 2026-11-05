# T020 — preserve original and accepted edited images

The previous import flow uploaded only the displayed edit and discarded its source after accepting the draft. The server then flattened transparency to JPEG. This change retains the metadata-free normalized source JPEG and the accepted edited PNG together through draft retry, the protected offline outbox, and server publication.

## Contract

- The existing image ID identifies one upload operation and its variants. `hasCleanedImage` on wardrobe items indicates an accepted edit is available.
- `POST /v1/images/uploads` accepts optional Boolean `has_cleaned` (default false). Its value is immutable for the operation ID. Single-photo clients remain compatible.
- For paired uploads, the response advertises `application/vnd.szafa.image-pair` and a maximum of 25,165,828 bytes: four unsigned big-endian bytes containing the original length, original bytes, then cleaned PNG bytes. Each image must be nonempty and at most 12 MiB. The PUT must use that content type; single-photo uploads retain their existing body.
- The source passes the bounded image normalizer and becomes `original.jpg`. The accepted edit must decode as a single PNG; only pixels enter a fresh PNG canvas, preserving alpha while stripping metadata. The thumbnail is generated from the edit. All files must be persisted before the database publishes the complete set under its upload fence.
- Authenticated signed download routes support `original`, `thumbnail`, and `cleaned`; the latter returns `image/png`. Purchase-preview uploads remain single-photo.
- Ready upload replay does not rewrite either asset. Owner checks, expiry, deletion fencing, and repeated orphan cleanup apply to the complete set. A missing paired variant invalidates the set.
- The native detail defaults to the accepted edit and offers its original toggle only when both exist. Lists use thumbnails. Local imports retain both bytes even without connectivity.

## Validation scope

Focused tests cover source/edit persistence across local restart, committed-upload timeout/replay, second-store reads, account deletion, explicit upload/fetch contracts, PNG alpha and metadata stripping, and PostgreSQL publication/read/retirement behavior. Test outcomes are recorded after the checks complete. These fixtures do not constitute a real signed-in user acceptance session or a live deployment.

Migration 030 and the updated image service must be deployed together before the new paired upload contract is usable on staging. Neither is deployed by this PR. Migration 029 remains a separate task.

## Local results

- Release simulator: 60/60 tests passed (18 API client, 22 offline store, 20 photo import), including paired import and cleaned PNG fetch. Result bundle: `/private/tmp/T020ImagePairRelease.xcresult`.
- Disposable PostgreSQL 15: all migration files through 030 applied; image lifecycle, purchases, garment deletion, exports, and concurrent purchase-confirmation/sweep tests passed. The database was removed after the run. Log: `/private/tmp/szafa-t020-db.log`.
- Real Pillow decoder: four tests passed, including transparent and semitransparent pixels and metadata stripping. Image service tests exercise authenticated HTTP pair upload, fenced publication, source/cleaned reads, post-commit replay, and cleanup.
