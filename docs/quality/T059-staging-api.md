# Authenticated staging API baseline — 2026-11-06

Deployed gateway revision: `7b04e3af3fb6a856e220765986ae5bb69bfe11e9`.
The caller used a real emailed-OTP session for the dedicated synthetic staging
account. The workload contains 1,000 live garments, one deleted tombstone,
1,826 wear events covering 2021–2025 and 9,130 garment memberships. Synthetic
benchmark rows were inserted directly into this test account, so setup does
not establish write-API throughput or native editing acceptance.

Each operation had five excluded warmups and 100 sequential timed HTTP reads.
The measurement includes the gateway's managed-session check, database work,
response serialization and transport through the Mac-to-VPS SSH tunnel. It
excludes the Cloudflare edge, native rendering and physical-device networking.
Every response was checked for success; page sizes and full snapshot garment/
history counts were verified. Percentiles use nearest rank. Private raw samples
are retained in `private-runtime/staging-e2e/large-wardrobe-benchmark.json`.

| Operation | p50 ms | p95 ms | Maximum ms |
| --- | ---: | ---: | ---: |
| First wardrobe page (40 items) | 639.564 | 1041.906 | 1076.086 |
| Last wardrobe page (40 items) | 724.993 | 1036.931 | 1365.917 |
| Garment detail | 555.273 | 640.963 | 669.976 |
| Full sync snapshot | 832.418 | 1176.041 | 1454.696 |

Three operations exceed the 800 ms API p95 target. These are baseline failures,
not a successful performance acceptance report.

## Round-trip reduction

Previously each RPC did a standalone session transaction, then repeated the
same database session/deletion check inside the operation transaction. The HTTP
RPC path now performs the real managed-provider session check and delegates
directly to `GatewayStore.rpc`, which still binds the session and enforces the
deletion ledger inside the operation's transaction before executing under the
authenticated role. Other route types retain their existing authentication flow.

The constant BEGIN/SET LOCAL ROLE/SET LOCAL statement_timeout setup is sent as
one simple-protocol query. User data and operation payloads remain parameterized
in their own queries; no session checks, role boundaries or timeouts are removed.
Rollback and commit still return pooled connections without a persistent role
or timeout change. Real PostgreSQL HTTP tests cover ownership, revocation,
deletion fences and pooled-connection isolation.

This removes redundant database network round trips; it does not cache identity
or bypass live session validation. Repeat the same hosted workload after a
reviewed deployment before claiming a measured improvement. Full public-origin,
native and reliability acceptance remain separate T059/T060 gates.
