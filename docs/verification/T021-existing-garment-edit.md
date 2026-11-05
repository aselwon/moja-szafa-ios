# T021 — Edit an existing garment

The garment detail screen opens the full garment form with the saved values,
including pattern, formality, purchase date, and other metadata. Saving retains
the same garment ID and preserves its photo, wear history, and current
availability/archive state. Edits use the existing versioned offline outbox;
stale versions fail as conflicts, and pending writes remain available across
restart.

## Verification

- 50 focused native tests passed. Coverage includes loading and editing the
  complete form, preserving identity/photo/history/status, offline edit and
  durable restart, stale-version rejection, and the existing import and wear
  flows.
- Disposable PostgreSQL 15.19: bootstrap and migrations 001–029 applied; the
  API, wardrobe, import-metadata, and garment-edit SQL suites passed.
- No live authenticated backend or end-to-end UI session was used; this does
  not establish live-service or production acceptance.
