# T005 — iOS project and architecture

## Build baseline

The repository contains a native SwiftUI iPhone application, an XCTest target,
and the shared `MojaSzafa` scheme. No package manager, generator, downloaded
fonts or third-party dependencies are required. Open `MojaSzafa.xcodeproj`.

Use the current stable **Xcode** (CI uses the default Xcode of GitHub's
`macos-latest` runner, currently Xcode 26) with any available iPhone simulator. The source uses Swift 6 language mode, structured concurrency
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
Signing policy, environment separation and pinned CI are now documented in
[T006](../operations/T006-environments-ci.md). CI uses the runner's default Xcode
on `macos-latest` and runs all three configurations; it fails if the toolchain is unavailable. No CI execution
is claimed here. App Store icon/artwork and distribution setup are future work.

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

`AppDependencies.live()` is the only application composition, in both Debug
and Release. It injects `UnconfiguredWardrobeRepository`, which throws an
explicit configuration error and never returns fixtures, simulated success or
an empty wardrobe. The UI explains that the service connection is unavailable.
All successful fake repositories are confined to the test target, which is not
part of the app archive. There is no environment flag or launch argument that
can silently activate a demo backend in Release.

This fail-closed adapter is **not a real backend**. T007/T009 must replace it
with the authenticated implementation after contracts and access exist. The
minimal garment read model is not the complete schema. Local database, outbox,
CRUD, authentication and synchronization belong to their respective tasks;
no in-memory collection is presented as durable storage. The other three tabs
explicitly state that their features are pending. This is an architecture
foundation, not a usable wardrobe product or a release-ready build.

## Verification and evidence limits

`node scripts/harness-check.mjs` checks backlog integrity, T003 localization and
contrast, source-file references, the shared scheme and exact color-token parity.
It does not compile Swift or replace Xcode tests.

`MojaSzafaTests/ArchitectureTests.swift` covers live composition failing closed,
injected data, empty versus failed states, offline retry, cancellation and
concurrent request deduplication. A suspended actor-controlled repository makes
the concurrency test deterministic, without timer sleeps or network calls.

This Linux sandbox has neither Swift nor Xcode. Run the Debug tests and Release
build above on macOS and attach the actual `.xcresult`/logs before marking the
clean-checkout build criterion met. Also launch PL and EN, light and dark, at
AX5 and standard text size, and check all four tabs, error text, navigation and
VoiceOver. Do not interpret the static harness check as evidence of simulator,
physical-device, accessibility or CI success.
