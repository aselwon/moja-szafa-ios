# T003 — feature form layout and localized dynamic labels

## Issue and correction

Some views built runtime localization keys inside string interpolation passed to
`LocalizedStringKey`, for example
`LocalizedStringKey("garment.color.\(color)")`. SwiftUI treats the interpolation
as a localized format argument; it does not look up the assembled catalog key.
The UI could therefore display raw key text such as `garment.color.black`.

The 11 affected sites now assemble the complete key before creating the
`LocalizedStringKey`:

- Trips: `trips.category.<category>`.
- Garment form: `garment.category.<value>`, `garment.color.<value>`,
  `garment.season.<value>`, and `garment.formality.<level>`.
- Profile preferences: `profile.styles.<value>`, `profile.colors.<value>`, and
  `profile.priorities.<value>`.
- Subscription status: `subscriptions.status.<status>`.
- Purchase preview: garment category and season keys.
- Today: generation status and garment category keys.

All 52 reachable enum/list-generated keys have nonempty Polish and English
entries. The generation label is displayed only for `queued` and `running`.

## Opt-in UI coverage

`FeatureLayoutAccessibilityTests` opens a simulator-only verification root with
the `--feature-layout-test` launch argument. The app route is compiled only for
Debug simulator builds with `LAYOUT_VERIFICATION`; normal builds and CI do not
include or run this route. It uses a temporary local profile store and fixture
consent service and makes no network/provider requests. It hosts the production
profile editor, consent screen and garment form with local fixture state.

The UI test checks that profile preferences can be selected and saved, consent
can be granted and revoked, and a garment with a long name can be saved. It
captures form/action screenshots. This is a focused layout probe, not backend
persistence or full authenticated-app acceptance.

For a dedicated simulator, the opt-in invocation is:

```sh
xcodebuild test \
  -project MojaSzafa.xcodeproj \
  -scheme MojaSzafaUI \
  -configuration Debug \
  -destination 'platform=iOS Simulator,id=<dedicated-simulator-UUID>' \
  -parallel-testing-enabled NO \
  -only-testing:MojaSzafaUITests/FeatureLayoutAccessibilityTests \
  CODE_SIGNING_ALLOWED=NO \
  'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) DEBUG LAYOUT_VERIFICATION'
```

Set the dedicated simulator to AX5 (`accessibility-extra-extra-extra-large`) and
the intended light/dark appearance before running; restore its prior settings
afterward. The compilation condition is an explicit local verification flag,
not part of ordinary CI configuration.

## Executed evidence

- Polish run PL1 failed and exposed raw localization keys.
- Polish run PL2 passed in 64.910 seconds after correcting key construction.
- All four language/appearance combinations passed at AX5 on the iOS 27.2
  simulator: Polish-light, English-light, Polish-dark and English-dark.
- Root inspected representative screenshots from across the matrix, including
  the localized Polish profile, consent and garment forms, consent and
  garment-save actions, the Polish-dark consent action, and the
  English-localized garment form. Labels were translated and the observed
  actions remained reachable. Long consent-form content wraps; no claim is made
  that the single-line garment name field wraps or that every attachment was
  visually reviewed.
- Repository harness passed 92/92. Design validation reports 695 PL/EN keys and
  minimum declared contrast of 6.68:1.

This matrix covers the tested fixture screens and is not full-app accessibility
acceptance. T003 remains open for its broader product scope.
