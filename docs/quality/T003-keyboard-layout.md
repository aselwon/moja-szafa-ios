# T003 — garment form keyboard and price validation

The opt-in feature layout fixture now uses a 200-character garment name, the
accepted input boundary. The existing PL/EN form-action probes exercise saving
that valid fixture. New price-error probes open the real `GarmentFormView`, focus
its real decimal keyboard and enter an invalid amount with excess decimal places.

The keyboard probes verify:

- The fixture's name contains 200 characters and the actual edited price is
  `123.45123`, not an assumed cursor/input result.
- The focused price field lies above the keyboard.
- The complete Save button can be scrolled into the visible content area before
  tapping it; the keyboard's presence at that point is recorded in the test log.
- The localized price error appears, and the invalid input never invokes the
  local save callback.
- Save remains enabled and fully reachable after the long error is inserted;
  Cancel returns to the fixture list without saving.

The viewport helper accounts for the keyboard frame. `isHittable` alone is
insufficient: XCTest can report a form action as hittable even when the reported
frame is beneath the keyboard. Scroll gestures therefore start and end inside
visible form content, not inside the keyboard. Long error text remains scrollable
and is captured separately from the fully visible Save action.

These are Debug + `LAYOUT_VERIFICATION`, simulator-only probes through
`--feature-layout-test`; ordinary builds do not contain this fixture route.
No authenticated account, server save, provider or external resource is involved.
This verifies the native form and local validation/callback boundary, not backend
persistence or a full physical-device accessibility audit.

On an owned simulator configured for AX5 and the chosen appearance:

```sh
xcodebuild test -project MojaSzafa.xcodeproj -scheme MojaSzafaUI \
  -configuration Debug -destination 'platform=iOS Simulator,id=<owned-simulator>' \
  -parallel-testing-enabled NO \
  -only-testing:MojaSzafaUITests/FeatureLayoutAccessibilityTests/testPolishPriceErrorWithKeyboard \
  -only-testing:MojaSzafaUITests/FeatureLayoutAccessibilityTests/testEnglishPriceErrorWithKeyboard \
  CODE_SIGNING_ALLOWED=NO \
  'SWIFT_ACTIVE_COMPILATION_CONDITIONS=DEBUG LAYOUT_VERIFICATION'
```

Repeat for light/dark and require two executed tests per run. The existing
`testPolishFormActions` and `testEnglishFormActions` verify successful submission
of the same 200-character fixture. Retain screenshots and result bundles, and
restore the owned simulator's appearance/text size afterward.
