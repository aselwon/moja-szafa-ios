# T012 — recover an expired image upload

An interrupted upload could claim a server lease, fail before publication, and later become retired. Reusing that image ID could never succeed, leaving the durable offline import stuck even though its garment metadata had already been accepted.

The prepare endpoint now returns `409 image_upload_expired` only after checking the live owner, live garment, operation ownership and immutable photo shape. It retires the old fence and metadata namespace first. The client creates a new image ID, writes the same immutable original/edit payload under that ID, commits the new ID in its durable outbox and local garment, and only then retries. The garment ID and save-operation ID do not change. A saved local import receipt keeps a restarted import screen idempotent after image-ID rotation.

Retries are bounded to one replacement per synchronization pass. Other HTTP failures do not rotate identity. A second expiration enters the existing durable backoff. Old storage cleanup and delayed old writers operate on the old image ID, so they cannot overwrite or remove the replacement. Account/garment deletion continues to fence recovery.

Validation covers an expired first attempt followed by a committed replacement with a lost response, local restart, source/edit bytes, no duplicate garment, bounded retries, structured error classification, and real PostgreSQL delayed-writer/cleanup isolation. Test outcomes are recorded after execution; this is not evidence of a live signed-in acceptance session.

Migration 031 and the matching image handler are required for recovery on staging. Existing older server responses still fail closed and use normal backoff. No live migration or deployment is performed by this change.

## Verification outcomes

- Native iOS Release on the owned iOS 27.2 simulator: 64 tests passed with no failures — 19 API client, 22 offline store and 23 photo-import tests. This includes the durable replacement-ID/no-duplicate-garment case, repeated-expiry one-replacement-per-sync-pass case and explicit expired-response classification.
- PostgreSQL 15.19: migrations 001–031 applied in a disposable database; focused image, purchase, deletion, export and race checks passed. The disposable database was removed afterward.
- Repository harness: 86/86 checks passed; `git diff --check` passed.

These local results do not claim a live signed-in app acceptance session or a staging deployment of migration 031.
