# T012 — Offline garment import

Photo imports now enter the account-scoped durable `OfflineStore` before any
network request. The store keeps the garment mutation, wear history, upload
bytes, and stable operation/image IDs across restart. Synchronization replays
the metadata save and photo upload idempotently; an uncertain timeout leaves
the same operation available for retry. Local account deletion clears queued
work and fences late in-flight responses from repopulating the store.

## Verification

- Focused Release tests: 40 tests passed, plus the dedicated in-flight photo
  deletion test passed (41 total). Tests use a real temporary `OfflineStore`
  and a synthetic remote. They cover offline import of two visually identical
  garments as separate items, edits and wear while offline, persistence across
  restart, commit/upload timeout and replay, and account deletion with queued
  and in-flight photo work.
- `node scripts/harness-check.mjs`: 86 tests passed, with migration,
  localization, project, and contract checks.
- `git diff --check` passed.

These tests do not contact a live backend. Live upload/readback and production
deployment acceptance remain unverified.
