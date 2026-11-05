# T011/T024 image-retention verification

The gateway starts its image-retention sweep at startup and waits ten seconds
after each completed sweep before the next one. A full batch of 100 items
schedules the next batch immediately. The worker invokes only the fixed database
operations that select eligible retired
or expired uploads and acknowledge an item after its storage cleanup succeeds;
clients cannot supply an arbitrary sweep or cleanup operation.

For each selected upload, the storage adapter removes `original.jpg`,
`thumbnail.jpg`, and `cleaned.png`. The database acknowledgment happens only
after all three removals succeed. A storage error leaves the item unacknowledged
for a later retry. The integration test also verifies that a live image remains
readable while retired images are removed.

## Verification performed

- `node --test backend/tests/image-retention.test.mjs`: 1/1 passed. This uses a
  temporary local filesystem directory and verifies retry after a filesystem
  removal failure, preservation of unselected files, and removal of the remaining
  variants after retry.
- `node scripts/harness-check.mjs`: 88/88 passed.
- `GATEWAY_PG_TESTS=1 node --test backend/gateway/postgres.test.mjs`: 1/1 passed
  against the existing disposable PostgreSQL 15 container. This runs the
  gateway bootstrap and SQL migrations, creates synthetic upload records and
  temporary image files, exercises the real retention worker, checks the bytes
  for all three variants are removed for retired uploads, and confirms the live
  image bytes remain preserved.

These checks validate the local implementation and disposable test database.
No staging or production deployment was performed, and no remote image data was
changed.
