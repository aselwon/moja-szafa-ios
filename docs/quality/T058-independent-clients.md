# T058 — independent client conflict verification

Two independent OfflineStore actors use separate durable SQLite databases and the same synthetic remote. Both clients edit the same server version and start synchronization tasks. The test requires exactly one success and one version conflict, preserves the losing proposal across a store restart, and requires explicit resolution with a new operation ID against the winning version. Both clients must then converge without changing the existing wear event or purchase price.

A second scenario queues an edit on one client while the other deletes the garment. After the stale client restarts, pulling the tombstone must prevent transmission of its pending edit. Keeping the local proposal is rejected; accepting the deletion clears the blocked outbox without recreating the garment.

The gateway PostgreSQL integration additionally sends concurrent HTTP writes through the real gateway, restricted database role and application SQL functions in a disposable local database. It verifies a single winning write, explicit conflict resolution, idempotent replay of the old winner without overwriting the resolved state, and a durable deletion fence against a subsequent stale write. This tests real PostgreSQL behavior independently of the native remote fixture.

## Reproduction

- Run the `OfflineStoreTests` class with the normal MojaSzafa Xcode scheme on a dedicated simulator.
- Run `GATEWAY_PG_TESTS=1 node --test backend/gateway/postgres.test.mjs` using the repository's disposable PostgreSQL integration environment and locked gateway dependencies.
- Run `node scripts/harness-check.mjs` with the documented image-decoder dependencies.

## Evidence limits

The native remote is synthetic, while the gateway test uses actual local HTTP and PostgreSQL with synthetic provider identities. These tests are not two physical devices, real managed-provider login, or authenticated staging acceptance. T058's network-loss during photo upload, logout/account isolation and physical-device checks require their own evidence; these scenarios do not substitute for them.
