# T057 — Accessibility layout correction (partial)

`WardrobeThumbnail` now accepts an optional height while retaining its 150-point
wardrobe default. The Today suggestion replacement row requests a 64-point image
through that parameter instead of placing a 150-point thumbnail inside a 64-point
frame. The thumbnail is decorative in that row and is hidden from VoiceOver; the
garment name remains the row's accessible content.

The Debug demo banner now occupies its own vertical layout space above the tab
view and can grow vertically with Dynamic Type. This avoids overlaying the
navigation title and filters in the demo screen.

## Local verification

The Debug `MojaSzafa` app built successfully for the dedicated iOS 27.2 simulator
with `CODE_SIGNING_ALLOWED=NO`. The local `--demo` screen was captured at default
`large` text and at `accessibility-extra-extra-extra-large`. Visual review found
the demo banner, Wardrobe title, and filters clear at both sizes.

Screenshots were kept outside the repository:

- Default text: `/private/tmp/T057-default-text-after.png`
- Largest accessibility text: `/private/tmp/T057-large-text-after.png`

The demo contains Wardrobe, Outfits, and an About screen. It does not reach the
Today suggestion replacement picker, so the changed 64-point row was not exercised
in this visual run. This is not a full accessibility sign-off. VoiceOver flows,
PL/EN, dark mode, Reduce Motion, physical-device layout, and the full screen matrix
remain to be checked.
