# T057 — Native welcome action regression tests

The opt-in `MojaSzafaUI` scheme launches the actual Debug application, scrolls
the welcome screen, checks both actions are reachable, and taps Continue to
open the localized email field. It runs independently in Polish and English.
It does not use the demo root, create a session, or submit an email address.
The Debug-only launch argument resets only `welcome.seen.v1`.

## Verified scope

On 2026-11-05, both tests passed on the dedicated iOS simulator with
`accessibility-extra-extra-extra-large` text in light appearance (2/2), then
passed again in dark appearance (2/2) using the same compiled test bundle.
Each test keeps a screenshot of the actions before tapping Continue.

Local result bundles:

- `/private/tmp/T057WelcomeUILight.xcresult`
- `/private/tmp/T057WelcomeUIDark.xcresult`

### Integrated UI verification — 2026-11-06

After integrating the accessibility UI branch with main `fea90c5`, the
`MojaSzafaUI` scheme built successfully with `build-for-testing` and both
localized tests passed again on the dedicated iOS 27.2 simulator
`51C1DCC4-7F9F-4BB6-A4CC-9EF27B3DD2D5`: English and Polish in light mode (2/2),
then English and Polish in dark mode (2/2), all at
`accessibility-extra-extra-extra-large`. The same compiled bundle was reused
for the dark run. The four screenshots are stored under
`private-runtime/t057-ui-evidence/integrated-20261106/`, with result bundles at
`/private/tmp/T057IntegratedUILight.xcresult` and
`/private/tmp/T057IntegratedUIDark.xcresult`; the detailed receipt is
`private-runtime/t057-ui-evidence/receipt.json`. The dedicated simulator was
restored to light appearance and large content size.

After these UI runs, main advanced to `84bb2c6` through PR115, which only adds
recovery SQL and operations documentation. That merge introduced no app or UI
test changes, so this recorded UI result remains scoped to the same interface.

The tests assert the translated Continue label and the real sign-in email
field. They check Skip is hittable, but do not activate it. This is evidence
for welcome action reachability and navigation only. It does not establish
VoiceOver reading order, contrast, Reduce Motion, physical-device behavior,
or accessibility of authenticated flows. T057 remains incomplete.

## Reproduction

Use a dedicated simulator, set its preferred content size to
`accessibility-extra-extra-extra-large`, and set light appearance. Run:

```sh
xcodebuild test -project MojaSzafa.xcodeproj -scheme MojaSzafaUI \
  -destination 'platform=iOS Simulator,id=<dedicated-simulator-uuid>' \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO
```

Repeat in dark appearance. The text size and appearance are simulator settings,
not assertions imposed by the test; record them with the result. Restore the
dedicated simulator settings afterward. Do not reset a shared Simulator service
or alter a user's running preview to execute this suite.

The five required CI checks retain their existing schemes. This opt-in suite
does not replace any required check or authenticated acceptance test.
