# T025 — Potential duplicate photos

The garment form checks the original import against other local drafts and all
pages of active and archived wardrobe items for the current account. Wardrobe
images use the existing authorized thumbnail repository. It does not consult
another account, upload photos for analysis, or persist fingerprints.

Matching uses SHA-256 for identical bytes and mean RGB distance (at most 8/255)
on an orientation-corrected 8×8 white-backed rendering for similar images.
Decoding and fingerprinting run on an actor outside the UI executor. This is an
advisory heuristic, not garment identity recognition. Different angles, crops,
backgrounds or thumbnail processing can cause missed matches; similar colors
and layouts can cause false positives. Comparison uses originals, so changing a
local crop does not hide an identical source photo.

The form displays up to five matching photos and available names. The save
button explicitly offers to save a separate item when matches are present.
Nothing is merged, deleted or rejected by this check. The import form now
commits completed items through the wardrobe metadata and photo upload path;
see [T025 import/save verification](T025-import-save.md). Missing backend
configuration, cached pages, unreadable photos and failed requests mark the
review incomplete. Reopening the form reruns the check. Large wardrobes require
sequential thumbnail reads; review is cancellable when the form closes.

## Automated verification

- `export PATH=/home/harness/.local/bin:$PATH && node scripts/harness-check.mjs`
  passes in the Linux sandbox. This includes structural iOS checks, not Swift
  compilation or execution.
- `PhotoImportTests` adds identical/re-encoded/unrelated image comparisons,
  invalid-image handling, self exclusion, two separate saved copies across
  reopening, removal, active/archive pagination and incomplete-review coverage.
- Run the shared `MojaSzafa` test scheme with the repository's macOS CI workflow
  to compile and execute XCTest. Xcode is unavailable in this sandbox.

## Manual acceptance on iPhone/simulator (pending)

1. Import the same photo twice, open the second item's form and inspect the
   matching photo. Choose **Save as a separate item**. Save the first item too;
   reopen the app and verify both drafts and their metadata remain independent.
2. Add a recompressed copy, a different photo, and a photo already present in
   the active/archived wardrobe. Confirm useful warnings and inspect any false
   positives; no action should merge items automatically.
3. Disconnect the network with uncached wardrobe images. Confirm the incomplete
   review message and that the pending import remains available for retry; do
   not expect a new wardrobe item until metadata and photo upload are confirmed.
4. Review PL/EN, VoiceOver, large Dynamic Type and dark mode. The warning,
   previews, cancel and save controls must remain accessible.

These device checks and green macOS CI are not claimed as executed here.
