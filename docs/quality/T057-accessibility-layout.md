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

## Welcome screen follow-up

The Release `MojaSzafa` app was built and launched on the owned iOS 27.2 simulator
with no sign-in, demo flags, or network-backed account. The welcome title no longer
truncates at the observed sizes. At `large`, it wraps to two lines; at
`accessibility-extra-extra-extra-large` (AX5), it wraps to three lines in Polish and
four in English. The page content extends below the viewport at AX5. The assigned
simulator was restored to its original Polish, `large`, light-appearance settings
after capture.

The screenshot matrix is stored outside the repository:

- Polish, `large`, light: `/private/tmp/T057-Welcome-PL-Large-Light.png`
- Polish, `large`, dark: `/private/tmp/T057-Welcome-PL-Large-Dark.png`
- English, `large`, light: `/private/tmp/T057-Welcome-EN-Large-Light.png`
- English, `large`, dark: `/private/tmp/T057-Welcome-EN-Large-Dark.png`
- Polish, AX5, light: `/private/tmp/T057-Welcome-PL-AX5-Light.png`
- Polish, AX5, dark: `/private/tmp/T057-Welcome-PL-AX5-Dark.png`
- English, AX5, light: `/private/tmp/T057-Welcome-EN-AX5-Light.png`
- English, AX5, dark: `/private/tmp/T057-Welcome-EN-AX5-Dark.png`

The initial launch frame was blank while the app was rendering; it was not used as
evidence. A later settled capture showed the welcome screen. Actual scrolling and
reachability of the bottom actions were not verified because the Mac was locked and
the UI automation tool could not access Simulator. The tool reported that automatic
unlock failed; no attempt was made to bypass the lock. This is an eight-screenshot
welcome-screen matrix only, not a full-app accessibility sign-off. Button reach,
VoiceOver interaction, Reduce Motion, and physical-device behavior remain
unverified.
