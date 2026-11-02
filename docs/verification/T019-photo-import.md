# T019 — Camera and batch photo import

Implemented entry point: Wardrobe → Add photos. PhotosPicker uses the current file
representation (including HEIC), reads at most 10 MiB + 1 byte, and rejects sources
over 10 MiB before decoding. Each batch accepts up to 20 selections and processes
one at a time. ImageIO applies orientation, downsamples the longest edge to at most
1600 pixels without upscaling, then encodes JPEG at 0.82 quality without copying
source metadata. The camera requests permission only after tapping Take photo.
Its UIImage capture is encoded as JPEG before entering the same validation queue.
The size limit for camera captures applies to that JPEG representation.

Each selection has its own UUID and waiting/processing/ready/error/cancelled state.
A failed item does not stop the batch. Cancel keeps already completed drafts and
cancels remaining work; select failed/cancelled photos again to retry. Cancelling
the system picker or camera creates no draft. Navigating back leaves the queue
owned by the wardrobe screen. Ready means an atomic local write completed, not
that an upload or garment creation succeeded.

Completed JPEG drafts live under Application Support/PhotoDrafts/<account UUID>,
with complete file protection, and are restored for that account after relaunch.
Remove draft deletes the corresponding file. Pending work and error rows are not
restored after process termination; previously completed files remain available.
These are local source drafts, not synced garments. Cropping, segmentation, garment
forms and upload handoff belong to subsequent tasks. No AI/network API is called
by this feature (PhotosPicker may fetch an iCloud asset through the system).

## Checks performed in the Linux sandbox

- `export PATH=/home/harness/.local/bin:$PATH && node scripts/harness-check.mjs`
  passed, including Xcode source registration and PL/EN catalog checks.
- XCTest tests added for all eight EXIF orientation dimensions, downsampling,
  GPS removal, HEIC conversion, bounded input size, corrupt/unsupported inputs,
  empty selection, partial success, cancellation, disk errors, deletion and restart.
- Xcode, UIKit runtime and physical iPhone are unavailable here. XCTest has not
  been executed; structural harness checks are not compilation evidence.

## Required Apple-platform verification

1. Run the existing macOS CI workflow (Debug simulator tests and Release build).
   Confirm PhotoImportTests executes. If the simulator cannot encode HEIC, its HEIC
   test explicitly skips: execute on an HEIC-capable iPhone instead.
2. On a physical iPhone, allow camera access; capture portrait and both landscape
   orientations. Verify previews are upright. Cancel before capture and after
   retaking; no erroneous draft should appear. Deny permission on a fresh install;
   verify the library remains usable and Settings allows recovery. Verify unavailable
   camera handling on the simulator and restricted camera access on a managed device.
3. Import real JPEG/HEIC (including mirrored EXIF orientations), an unsupported PNG,
   an oversized >10 MiB JPEG, and an iCloud-only photo. Verify per-item states and
   successful previews survive neighboring errors. With iCloud offline, verify a
   failed download can be retried by selecting it again.
4. Cancel during a mixed batch, leave and return to the screen, then terminate and
   relaunch. Completed drafts must remain readable and cancellation must not remove
   them. A different signed-in account must not show the previous account's drafts.
5. Inspect exported test output metadata: max dimension <=1600, JPEG, no source GPS;
   visually check asymmetric/mirrored fixtures, not just their dimensions.
6. Check PL/EN, dark mode, largest Dynamic Type and VoiceOver on the import list.
   Confirm actions and per-item statuses remain accessible.

No claim of device verification, green remote CI or backend deployment is made.
