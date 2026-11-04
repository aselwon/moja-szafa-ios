# T024 verification

Permanent deletion queues an idempotent mutation and persists a scrubbed identity
fence in the same SQLite transaction. Archive remains the ordinary reversible
control. The separate destructive action explains loss of photos, memberships,
history and changes to derived statistics, including offline delivery.

The server locks the garment against concurrent writes, scrubs its attributes,
removes image/outfit/wear/trip memberships and clears purchase references. The
identity row remains to reject stale creates and edits. Existing derived reads
use remaining rows; there is no aggregate counter to decrement. Empty wear events
retain their identity for replay safety. The private upload ledger survives:
`backend/images/cleanup.mjs` repeatedly removes retired object directories,
including delayed writers. Run that worker with the configured private volume.

Verification outside this Linux sandbox:

- Run macOS CI (Xcode build and XCTest), including the new OfflineStore tests.
- Run `bash backend/tests/run-tests.sh` with PostgreSQL 15. The suite runs the new
  deletion contract on fresh and upgraded databases.
- On an iPhone, archive and restore an item, then permanently delete it after
  cancellation once. Check PL/EN, VoiceOver and large text confirmation.
- Delete offline, restart, reconnect and sync a second device with a stale edit.
  Confirm the item stays absent, remaining history survives and outfits show
  missing pieces rather than inventing replacements.
- With the image service and sweeper running, delete an item with uploaded photos;
  verify access is denied and original/thumbnail files disappear. Restart the
  sweeper during cleanup and confirm eventual removal.

Ambiguous previously sent wear operations that reference a deleted garment are
retained as conflicts rather than rewriting their idempotency payload. They need
explicit recovery; unsent wear operations retain only surviving garment IDs.
Physical image deletion is eventual and depends on the sweeper being operated.
No deployment or device verification was performed here.
