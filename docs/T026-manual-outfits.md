# T026 manual outfits

The Outfits tab loads saved outfits and pages through active and archived wardrobe
metadata. The editor composes real thumbnails, names the outfit, toggles favorite,
and replaces ordered membership atomically. Archived items remain selectable for
historical/manual composition and carry a textual warning in the picker and collage.
Availability is displayed; creating a manual collection does not record a wear.
Missing photos have a placeholder. Cancel discards editor changes.

## RPC contract (v1)

Both authenticated POST RPCs use the existing APIClient envelope and account token.
`api_v1_list_outfits` takes `{}` and returns `data: Outfit[]` ordered by creation/ID.
`Outfit` is `{id: UUID, version: positive integer, name: string,
favorite: boolean, garmentIDs: UUID[]}`. No photo bytes or storage URLs are included.

`api_v1_save_outfit` takes `{operation_id: UUID, outfit_id: UUID,
base_version: positive integer | null, outfit: {name: string,
favorite: boolean, garmentIDs: UUID[]}}` and returns `data: Outfit`.
Null base version creates; an existing version edits. Name is trimmed, 1–200
characters, selection has 1–100 unique owned non-deleted garment IDs. Ordered IDs
become collage order. Errors use `code/message/request_id`: validation_failed,
version_conflict, idempotency_conflict, unauthorized, account_unavailable,
internal_error. Idempotency responses and membership commit in one transaction.
Garments are locked against concurrent changes during validation. Neither RPC
writes wear events or their historical membership.

Ambiguous failures retain the exact operation UUID and draft in the current tab
model; retry resends the same intent. Close/reopen resumes pending work. Definitive
conflicts require closing, refreshing and editing the current server version.
Outfit offline writes are not queued durably: interrupted drafts do not survive
process termination. Existing wardrobe offline data can supply thumbnails/metadata
only to the extent supported by its repository; an outfit load/save requires the
configured backend. No mock backend is installed in release.

## Verification outside this Linux sandbox

- Run `bash backend/tests/run-tests.sh` against disposable PostgreSQL 15 databases:
  includes outfits.sql on fresh and upgraded databases (save/edit/replay, ownership,
  version conflict, rollback, archive membership and unchanged wear history).
- Run the shared MojaSzafa Xcode test scheme in Debug, Staging and Release on macOS.
  OutfitsTests covers draft validation, wire encoding, timeout retry, editing,
  favorite persistence and unknown selection rejection.
- With a configured backend and private garment images: create an outfit, cancel
  an edit, reopen, rename, replace items, favorite/filter and relaunch. Archive one
  selected garment and refresh: both picker and collage must warn. Compare wear
  history before/after editing. Disconnect during save and retry after reconnect.
- Check PL/EN, dark mode, largest Dynamic Type and VoiceOver on iPhone, including
  long names and unavailable images. Capture screenshots from that real build.

The collection RPC currently returns all saved outfits; wardrobe input is paginated.
Large outfit libraries may need collection pagination in a future performance task.
Production backend configuration remains subject to the existing access/setup gates.
