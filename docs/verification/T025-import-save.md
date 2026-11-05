# T025 — Import a garment into the wardrobe

The photo-import form now commits a completed garment as a wardrobe item. The
form creates an immutable operation and freezes its photo bytes in protected
local storage. `OfflineStore.importGarment` sends the garment metadata, uploads
the photo, and checks a fresh account snapshot for the same garment and image
IDs. A retry after timeout or relaunch reuses the operation, garment, and image
IDs. Local draft files are removed only after both server writes are confirmed.
Each import has its own IDs, so visually identical items remain separate.

Migration 028 adds optional validated garment metadata for colors, seasons,
pattern, formality, brand, and purchase date. Existing garment updates can omit
that metadata without clearing it. This change does not alter wear history or
cost-per-wear values.

## Verification

- Focused Release XCTest: `APIClientTests` 16/16 and `PhotoImportTests` 17/17
  (33 total). The import tests exercise `PhotoImportModel` through a real
  `OfflineStore` and fake remote, including commit/upload timeout, restart,
  stable IDs, two identical items, photo bytes, and a second store. They do not
  contact a live backend.
- PostgreSQL 15.19 disposable test: migrations 001–026 and 028 applied; the
  existing `api.sql` and new `import-metadata.sql` passed. Assertions cover
  exact mutation replay, import metadata, a distinct second identical garment,
  metadata preservation on older updates, and rejection of invalid metadata.
- `node scripts/harness-check.mjs` passed: 82 Node tests plus structural,
  localization, migration, and project checks.

The native/backend integration is implemented and locally tested, but a live
gateway/Neon upload and readback, real device restart, and production deployment
have not been verified. Do not treat the local fake-remote tests as live service
acceptance.
