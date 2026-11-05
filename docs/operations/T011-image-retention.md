# T011/T024 image-retention verification

The gateway starts its image-retention sweep at startup and repeats it every ten
seconds. A full batch of 100 items schedules the next batch immediately. The
worker invokes only the fixed database operations that select eligible retired
or expired uploads and acknowledge an item after its storage cleanup succeeds;
clients cannot supply an arbitrary sweep or cleanup operation.

For each selected upload, the storage adapter removes `original.jpg`,
`thumbnail.jpg`, and `cleaned.png`. The database acknowledgment happens only
after all three removals succeed. A storage error leaves the item unacknowledged
for a later retry. The integration test also verifies that a live image remains
readable while retired images are removed.

## Verification performed

- `node --test backend/tests/image-retention.test.mjs`: 1/1 passed. This uses a
  temporary local filesystem directory and verifies retry after a removal
  failure, preservation of unselected files, and removal of all three variants.
- `node scripts/harness-check.mjs`: 88/88 passed.
- `GATEWAY_PG_TESTS=1 node --test backend/gateway/postgres.test.mjs`: 1/1 passed
  against the existing disposable PostgreSQL 15 container. This runs the
  gateway bootstrap and SQL migrations, creates synthetic upload records and
  temporary image files, exercises the real retention worker, and confirms
  retired metadata is acknowledged only after deletion while a live image is
  preserved.

These checks validate the local implementation and disposable test database.
No staging or production deployment was performed, and no remote image data was
changed.
