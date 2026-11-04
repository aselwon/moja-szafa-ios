# T047 — Outfit collage export

## Implementation

Open an outfit in Outfits, then choose **Export collage**. The current selection
is captured as a value snapshot. A separate preview renders only those photos,
with a fixed PL/EN caption. **Share…** opens `UIActivityViewController` with exactly
a newly drawn image and that caption. No domain objects, names, prices, IDs,
original files, source metadata or signed URLs enter the activity items.

Rendering uses authenticated repository thumbnails (including the existing
repository's offline cache), a 1200 × 1200 white canvas and aspect-fit images.
There are no export files left in application storage. Missing/invalid photos
and network failures block sharing and expose retry; closing preparation cancels
its task. Empty outfits cannot start export. Nothing is automatically published,
and no public profile or publishing service is added.

## Evidence and remaining checks

- Passed in Linux sandbox: `node scripts/harness-check.mjs` and `git diff --check`.
- Added `OutfitExportTests` to the existing XCTest target: selected image requests,
  rendered photo colors, payload types, invariance under private field changes,
  absence of image metadata, missing/corrupt/offline photos, retry and cancellation.
- XCTest and native UI execution require macOS/Xcode; neither was available here.
  Run the existing CI `ios` job for Debug, Staging and Release and retain xcresults.

## Manual acceptance on iPhone

1. Use an authorized test account with two visually distinct outfits. Include
   private names and prices in the records. Open one outfit and export it.
   Confirm the preview contains exactly its selected photos and the fixed caption.
2. Tap Share and confirm the system activity sheet appears. Send to a controlled
   destination (for example, a test Notes entry). Inspect the resulting image and
   text: no names, prices, UUIDs, source links or EXIF/GPS metadata from the records.
   Some destinations may accept only the image or only the text.
3. Cancel both the activity sheet and preview. Reopen a different outfit and
   verify no stale photo selection. Cancel while photos are loading; verify no
   late presentation. Confirm no upload/publication occurs from preview or cancel.
4. Test an empty outfit, missing photo, corrupt photo response, and offline cache
   hit/miss. Sharing must remain unavailable on failure; retry after reconnecting.
5. Check 1, 2, 3 and 100 photos, portrait/landscape orientation, PL/EN, dark mode,
   largest Dynamic Type and VoiceOver. Actions must remain accessible by scrolling.
6. Retain screenshots of preview and system sheet from the actual build, without
   real customer data. This sandbox did not produce device screenshots.

The export deliberately preserves visible photo content. Text or personal details
already photographed are not redacted; the preview explains this before sharing.
