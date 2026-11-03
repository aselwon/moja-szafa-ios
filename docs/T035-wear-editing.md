# T035 — wear creation and editing

The Today tab lists durable wear events and opens an editor for local calendar date
and garment membership. “Wear today” on an outfit copies its current IDs into a new
editable event. Saving an outfit alone never records wear. Existing event timezones
are retained when editing after travel; `wornOn` is a DATE string, not a timestamp.

`api_v1_save_wear` accepts version zero for creation and the last acknowledged
positive version for editing. Migration 013 replaces the RPC without rewriting old
migrations. Ownership checks, event mutation, replacement of `wear_event_items`,
and the replay response are one PostgreSQL transaction. Stale versions and deleted
events return `version_conflict`. A replay uses the original operation UUID and
payload; changing either the date or membership requires a new intent after ack.
Future dates are rejected in the event timezone, locally and by the database.

SQLite persists the event and outbox together. Unsent edits can be coalesced;
requests already sent cannot be changed until acknowledged or explicitly resolved.
Pulls preserve pending edits; tombstones hide them and block retransmission.
Conflict resolution fetches the server version, then accepts it or creates a new
operation retaining local fields. Tombstones cannot be revived. Counts use distinct
`wornOn` values for each garment across active historical events, not outfit contents.

## Verification

- Run `node scripts/harness-check.mjs` with the harness Node PATH.
- Run `bash backend/tests/run-tests.sh` against disposable PostgreSQL 15 databases.
  This includes `wear-editing.sql` on fresh and upgraded schemas, plus concurrency
  coverage in `wear-concurrency.sh`.
- Run the existing macOS CI matrix (Debug, Staging, Release). `OfflineStoreTests`
  covers editing, restart/timeout replay, conflict/tombstone handling, invalid dates,
  timezone boundaries, shared-day counts, and local disk-failure atomicity.
- On a configured iOS build, create two outfits sharing one garment, record both
  on one day, edit one event's date and membership, and inspect garment history.
  Change the phone timezone and reopen the event: its saved date/timezone must stay
  unchanged. Repeat offline, restart, reconnect, and resolve a two-device conflict.
  Check large Dynamic Type, VoiceOver, cancel, errors and empty history.

The Linux sandbox has neither Xcode/Swift nor PostgreSQL tools. The harness check
is not evidence that XCTest or database integration tests passed. No backend was
deployed and no device test was performed. Existing live configuration remains
fail-closed until service access is configured; configured compositions expose the
feature. Migration 013 must be applied before shipping an editing client.
