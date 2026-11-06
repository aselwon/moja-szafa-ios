# T003 — independent photo draft actions and large-text previews

## Reproduced failure

A photo draft has several buttons in one `List` row: garment details, photo
editing, optional recognition and removal. With SwiftUI's automatic row button
style, tapping **Edit photo** opened the garment form instead of the editor in
the native Polish, dark, AX5 probe. The retained failure screenshot shows the
actual garment form; this was not a missing localization key or a fake fixture
screen. The test failed while looking for **Preview with background**.

The draft row now uses the explicit `borderless` button style so each action has
its own target. The underlying edit, save, recognition and deletion callbacks
are unchanged. This scopes the change to rows containing multiple draft actions.

## Dark appearance contrast

The first successful dark-mode action probe also exposed white labels on the
light-green prominent buttons. Both photo acceptance and collage sharing now use
the existing semantic `onAccent` foreground paired with the `accent` tint. This
keeps the white label on the dark green light-mode background and uses the dark
label on the light green dark-mode background. The token contrast checks cover
this pair; screenshots must additionally verify the controls use it at runtime.
The declared sRGB color-pair ratios are 1.55:1 for the previous white-on-light-green
combination, 9.71:1 for the corrected dark-mode pair and 7.66:1 for light mode.
These are token calculations, not a claim that every rendered pixel has that ratio.

## Verification route

`PhotoLayoutAccessibilityTests` uses the `--photo-layout-test` route, compiled
only for Debug simulator builds with `LAYOUT_VERIFICATION`. Ordinary builds and
real devices do not contain the route. It uses `DemoWardrobe`'s locally rendered
images; no Photos library, camera, account, network or AI provider is accessed.

The fixture passes a JPEG through the real `PhotoImportModel.start` normalizer,
opens the production import list and editor, renders a preview with its original
background, and accepts it through `PhotoImportModel.acceptEdit`. The test
requires the editor action to remain reachable after acceptance, so deleting the
draft as a side effect cannot satisfy the test. It also opens the production
`OutfitExportView`, waits for the real local collage renderer, and checks the
localized Share button is reachable and enabled. It cancels the preview without
opening a sharing activity or sending anything.

Set an owned test simulator to `accessibility-extra-extra-extra-large` and the
intended appearance, then run:

```sh
xcodebuild test -project MojaSzafa.xcodeproj -scheme MojaSzafaUI \
  -configuration Debug -destination 'platform=iOS Simulator,id=<owned-simulator>' \
  -parallel-testing-enabled NO \
  -only-testing:MojaSzafaUITests/PhotoLayoutAccessibilityTests \
  CODE_SIGNING_ALLOWED=NO \
  'SWIFT_ACTIVE_COMPILATION_CONDITIONS=DEBUG LAYOUT_VERIFICATION'
```

Require a nonzero executed test count. A build without the verification condition
can succeed with zero tests and is not evidence. Restore simulator settings after
the probes. These checks do not establish background-removal quality, external
sharing delivery, authenticated persistence, or physical-device VoiceOver support.
