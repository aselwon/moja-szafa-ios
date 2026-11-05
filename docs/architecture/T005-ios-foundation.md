# T005 — iOS project and architecture

## Build baseline

The repository contains a native SwiftUI iPhone application, an XCTest target,
and the shared `MojaSzafa` scheme. No package manager, generator, downloaded
fonts or third-party dependencies are required. Open `MojaSzafa.xcodeproj`.

The locally verified toolchain is **Xcode 27.2 (build 27B52)**. CI uses the
runner-managed Xcode on GitHub's `macos-latest`; that toolchain is not pinned by
this repository. The source uses Swift 6 language mode, structured concurrency
and a deployment target of **iOS 17.0**. This is a provisional engineering
baseline, not an owner-approved support policy: product decision D08 still
needs confirmation of supported devices, OS versions and test hardware.
This does not assert that a given Xcode meets future App Store submission rules;
that verification belongs to T064.

From a clean checkout on that Mac:

```sh
xcodebuild -version
xcodebuild -list -project MojaSzafa.xcodeproj
xcodebuild test \
  -project MojaSzafa.xcodeproj -scheme MojaSzafa \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -derivedDataPath /tmp/moja-szafa-debug \
  -resultBundlePath /tmp/moja-szafa-tests.xcresult \
  CODE_SIGNING_ALLOWED=NO
xcodebuild build \
  -project MojaSzafa.xcodeproj -scheme MojaSzafa -configuration Release \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/moja-szafa-release \
  CODE_SIGNING_ALLOWED=NO
```

Use a fresh result-bundle path for each test run. Simulator builds require no
Apple account. Device builds require a real team and registered bundle ID;
`pl.mojaszafa.app` is a local project identifier, not a claimed registration.
Signing policy, environment separation and CI are documented in
[T006](../operations/T006-environments-ci.md). CI uses the runner's default Xcode
on `macos-latest` and runs all three configurations; it fails if the toolchain is
unavailable. PR #98 at head `b51e5c0bb4ea97c5fc05b58bab03fec4885624e3` passed
all five required checks and was merged into `main` at
`880fb50ac9e0c5fb429043ed55af37dbeaaf059e`. This is CI evidence for that
revision, not proof of physical-device, accessibility or production-service
acceptance. App Store icon/artwork and distribution setup are future work.

## Boundaries and dependency direction

These are logical feature modules in one application target, not separate
Swift packages. The layout can be split into targets when dependency size
justifies that complexity:

- `App`: entry point, four-tab navigation, composition root (`AppDependencies`).
- `Features/Today`, `Wardrobe`, `Outfits`, `Statistics`: independent UI entry
  points. Views do not instantiate infrastructure implementations.
- `Domain`: Sendable read model and async repository protocol; no SwiftUI import.
- `Data`: concrete repository implementations, depending on Domain only.
- `DesignSystem` and `Resources`: reusable UI and named Any/Dark colors from
  T003. The application compiles the original `design/Localizable.xcstrings`,
  with Polish development language and English localization.

Dependency flow: App wires Data into Features through Domain protocols.
`WardrobeModel` is main-actor isolated and receives `any WardrobeRepository`
through its initializer. `WardrobeView` owns it through `StateObject`; SwiftUI
`.task` owns asynchronous work and cancels it when the view disappears. Retry
changes the task identity. The model prevents concurrent duplicate loads,
checks cancellation after a provider returns, and restores the previous state
on cancellation. Cancellation is not shown as a user-facing failure.
Repository protocols are Sendable so future I/O can run off the main actor.

The model distinguishes loading, empty, loaded, unconfigured backend, offline
and generic failure. Error details are not displayed or logged. User garment
names render verbatim rather than as localization keys. Scrolling, semantic
fonts and system navigation preserve room for large text. No custom animation
or permission prompt is introduced. Device accessibility still needs testing.

## Production behavior and scope

`AppDependencies.live()` reads the public `BackendBaseURL` from the app bundle.
An empty, unresolved or invalid value returns an unconfigured repository; the
application does not substitute fixture data or simulated success. A valid HTTPS
gateway URL creates the authentication client and retains the same-origin API
connection. After authentication, `authenticated(using:)` supplies a
user-scoped token provider and composes `APIClient`, `OfflineStore` and the
feature repositories. Missing configuration, invalid authentication state or a
store-construction failure keeps the affected services unavailable. No network
request is made merely by composing the dependencies.

`APIClient` and `AuthenticationClient` reject non-HTTPS or malformed base URLs.
The build-environment guard also checks the environment name, bundle identifier,
endpoint mapping and signing overrides before compilation. The endpoint manifest
is configuration, not evidence that every service is deployed or that a
production user flow has been validated. Test doubles remain in the test target;
no environment flag or launch argument silently activates a demo backend in an
app archive.

## Verification and evidence limits

`node scripts/harness-check.mjs` checks backlog integrity, T003 localization and
contrast, source-file references, the shared scheme and exact color-token parity.
It does not compile Swift or replace Xcode tests.

`MojaSzafaTests/ArchitectureTests.swift` covers live composition failing closed,
injected data, empty versus failed states, offline retry, cancellation and
concurrent request deduplication. A suspended actor-controlled repository makes
the concurrency test deterministic, without timer sleeps or network calls.

The host toolchain was verified as Xcode 27.2 (build 27B52). This documentation
update did not rerun the Debug tests or Release build. Before treating the full
foundation and accessibility scope as accepted, launch PL and EN, light and
dark, at AX5 and standard text size, and check all four tabs, error text,
navigation and VoiceOver on the supported simulator/device matrix. Do not
interpret the static harness check or the PR #98 CI result as evidence of every
physical-device, accessibility or production-service criterion.
