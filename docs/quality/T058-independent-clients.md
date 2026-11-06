# T058 — independent client conflict verification

Two independent OfflineStore actors use separate durable SQLite databases and the same synthetic remote. Both clients edit the same server version and start synchronization tasks. The test requires exactly one success and one version conflict, preserves the losing proposal across a store restart, and requires explicit resolution with a new operation ID against the winning version. Both clients must then converge without changing the existing wear event or purchase price.

A second scenario queues an edit on one client while the other deletes the garment. After the stale client restarts, pulling the tombstone must prevent transmission of its pending edit. Keeping the local proposal is rejected; accepting the deletion clears the blocked outbox without recreating the garment.

The gateway PostgreSQL integration additionally sends concurrent HTTP writes through the real gateway, restricted database role and application SQL functions in a disposable local database. It verifies a single winning write, explicit conflict resolution, idempotent replay of the old winner without overwriting the resolved state, and a durable deletion fence against a subsequent stale write. This tests real PostgreSQL behavior independently of the native remote fixture.

## Reproduction

- Run the `OfflineStoreTests` class with the normal MojaSzafa Xcode scheme on a dedicated simulator.
- Run `GATEWAY_PG_TESTS=1 node --test backend/gateway/postgres.test.mjs` using the repository's disposable PostgreSQL integration environment and locked gateway dependencies.
- Run `node scripts/harness-check.mjs` with the documented image-decoder dependencies.

## Evidence limits

The native remote is synthetic, while the gateway test uses actual local HTTP and PostgreSQL with synthetic provider identities. These tests are not two physical devices, real managed-provider login, or authenticated staging acceptance.

## Interrupted transport and logout isolation — 2026-11-06

`backend/tests/images.test.mjs` now sends half of an image over a real local TCP
connection to the production image HTTP handler, waits until the server receives
bytes, then destroys the connection before its declared body length arrives.
It verifies that the operation remains pending, the decoder has not run, and no
partial file exists. Reconnecting with the same signed capability and complete
body succeeds; replay does not decode or publish again. This uses the production
normalizer and private file adapter, with a synthetic operation store and
authentication callback. It is a real transport interruption, not a simulated
exception after successful publication.

`ArchitectureTests.testLogoutAndAccountSwitchDoNotExposePreviousWardrobeCache`
uses production authentication composition and separate durable SQLite stores.
It loads account A's wardrobe, logs out, signs in as B, and disconnects resource
requests. B must see no A garments, wear history or pending writes, including
after reopening the store. A's stale store must reject synchronization before
sending any request with B's credentials. Existing per-account data is retained
for same-account offline use; this test does not require erasing it on logout.

Executed results: the initial focused Release `ArchitectureTests` suite passed
12/12 with zero skips on iOS 27.2 Simulator. After strengthening the new scenario
with actual account-A wear history and pending outbox state, its fresh Release
rerun passed 1/1 with zero skips (`/private/tmp/T058LogoutIsolationSeeded.xcresult`).
The integrated repository harness passed 92/92 (`/private/tmp/T058LogoutHarness.log`).
The image suite passed with the actual local socket interruption and real decoder.
The first image invocation lacked the worktree's native storage dependency;
installing the locked dependency resolved that setup failure without a product-code
change.

These checks strengthen two T058 scenarios but do not establish two physical
devices, photo-cache UI isolation, or a combined native-client-to-staging upload
interruption. Those remaining checks are not marked complete.
