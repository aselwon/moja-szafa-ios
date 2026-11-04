# T040 — Wardrobe review

The Statistics tab links to active garments with at most two recorded wear days in the last 90 calendar days. The rule is visible in the UI. Recent undated estimates are excluded rather than classified as rare from incomplete dates.

Each row offers:

- Find a saved outfit: searches every page of the owner's saved outfits for membership of this garment, then shows its real collage. No match has an explicit empty state directing the user to outfit creation. Viewing never generates AI or records wear.
- Keep: hides the row from this review on this device. This explicitly local choice survives relaunch, can be shown/undone, and changes no garment or wear data. Storage is account/gateway-scoped, protected and excluded from backups; account deletion removes it. Corrupt storage cannot silently overwrite choices and requires explicit local reset.
- Archive: uses the existing durable offline outbox and server version checks. The new field-specific operation preserves the current availability within the same actor transaction, so an old review row cannot overwrite a newer laundry state. Archived items remain accessible through the wardrobe's archive filter; history stays intact.

There are no monetary savings or environmental-impact claims. Tests cover persistent keep/undo, explicit corruption recovery, archived state and failures, later-page outfit discovery, estimate uncertainty, and unchanged availability/wear history during archiving.
