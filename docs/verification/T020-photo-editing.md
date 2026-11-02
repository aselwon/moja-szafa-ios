# T020 — Crop and background removal

Wardrobe → Add photos → Edit photo opens a scrollable, localized editor for each
completed draft. Four accessible sliders set crop dimensions (10–100% per axis)
and position. The original shows the crop outline; the rendered result appears
below it. Reset restores the full frame. Preview with background always provides
a path that does not invoke segmentation. Accept photo saves only the displayed
result. Cancel or dismiss discards unaccepted changes, including an in-flight
result. Changing the crop invalidates the preview so an outdated crop cannot be
accepted.

ImageIO crops the upright, metadata-free T019 import. Vision's iOS 17 foreground
instance mask runs locally on an actor, retaining all detected foreground instances
and the crop extent. The result is encoded as PNG to retain transparency. Errors,
including no foreground or unsupported execution hardware, leave the cropped
photo available with an explanation and retry. No external AI or paid API is used.

The original is the normalized T019 JPEG (at most 1600 pixels, not the full source
camera/library file). It is never overwritten by edits. Accepted pixels are written
atomically with complete file protection to a sibling UUID.png in the existing
account directory. The import list uses that PNG when present, including after
relaunch. Reopening the editor starts from the original; crop controls and temporary
previews are not persisted. Removing a draft removes both files. These remain local
drafts; this task does not implement garment creation or upload handoff.

## Sandbox verification

- `export PATH=/home/harness/.local/bin:$PATH && node scripts/harness-check.mjs`
  passes. This covers repository structure, localization, secrets and existing
  backend tests; it does not compile Swift or exercise Vision.
- Added XCTest coverage in PhotoImportTests for crop dimensions and pixel position,
  invalid bounds, segmentation failure with usable fallback, preview invalidation,
  successful result selection, transparency-preserving storage, cancellation,
  original preservation, replacement, restart, deletion and storage failure.
- Linux has no Xcode/UIKit/Vision runtime. Those XCTest cases have not run here.

## Required verification on Apple platforms

1. Run the existing macOS CI Debug simulator tests and Release build. Confirm all
   PhotoImportTests pass. The injected segmenter tests establish state behavior;
   they are not evidence of real Vision segmentation quality.
2. On a physical iPhone running iOS 17 or later, import portrait, landscape and
   mirrored JPEG/HEIC photographs. Move and resize the crop to each edge, render,
   and compare the outline with the result. Reset must restore the original frame.
3. Remove backgrounds from real garments against simple and cluttered backgrounds.
   Check foreground retention and transparent edges. Try blank/ambiguous images;
   if Vision fails, verify the message, retry and acceptance with background.
   Also explicitly choose Preview with background after successful segmentation.
4. Accept, relaunch, and check the selected image. Re-edit from the intact original.
   Cancel during processing and after preview; the previously accepted photo must
   remain selected. Remove the draft and inspect that neither JPEG nor PNG remains.
5. Check PL/EN, light/dark appearance, largest Dynamic Type and VoiceOver. Sliders
   must announce labels and values; all preview, retry, accept and cancel actions
   must remain reachable. Capture screenshots from that real build for review.

Both acceptance criteria are implemented, but Apple-platform runtime and visual
verification remain pending; no device or remote CI success is claimed.
