# T059 persisted wardrobe launch benchmark

This opt-in simulator test measures the real `WardrobeView`, `WardrobeModel`,
and `OfflineStore` with 1,000 synthetic garments and 1,826 daily wear events
(9,130 garment memberships, 2021-01-01 through 2025-12-31). The initial launch
seeds a separate SQLite file; subsequent launches reopen that same file rather
than generating an in-memory collection. Each launch validates the persisted
fixture counts and requires a visible, hittable first garment and a loaded
40-item page.

The test records two different measurements:

- `XCTApplicationLaunchMetric(waitUntilResponsive: true)` records the operating
  system's launch-to-responsive metric in the result bundle. It does not by
  itself establish that asynchronously loaded wardrobe data is visible.
- `T059-wardrobe-launch-2026-11-06.json` records process launch through first-page
  readiness as observed by XCTest. This includes test-driver launch and
  accessibility-query overhead, plus the fixture integrity check. Its p95 is
  the nearest-rank 19th sorted sample out of 20, after three explicit warm-ups
  and any XCTest measurement warm-up. It is an upper-bound simulator
  observation, not a physical-device launch SLA result.

## Reproduction

Use a dedicated iPhone simulator in its default text size. Do not run competing
builds or performance tests during measurement. Substitute its UUID below.
Use distinct, unused result paths when rerunning.

```sh
xcodebuild build-for-testing -project MojaSzafa.xcodeproj -scheme MojaSzafaUI \
  -configuration Release -destination 'platform=iOS Simulator,id=SIMULATOR_UUID' \
  -derivedDataPath /tmp/T059LaunchDerivedData CODE_SIGNING_ALLOWED=NO \
  SWIFT_ACTIVE_COMPILATION_CONDITIONS=WARDROBE_BENCHMARK
xcodebuild test-without-building -project MojaSzafa.xcodeproj -scheme MojaSzafaUI \
  -configuration Release -destination 'platform=iOS Simulator,id=SIMULATOR_UUID' \
  -derivedDataPath /tmp/T059LaunchDerivedData CODE_SIGNING_ALLOWED=NO \
  SWIFT_ACTIVE_COMPILATION_CONDITIONS=WARDROBE_BENCHMARK \
  -only-testing:MojaSzafaUITests/WardrobeLaunchBenchmarkTests \
  -resultBundlePath /tmp/T059WardrobeLaunch.xcresult
```

Record the actual Xcode version, simulator model/OS, host hardware, optimization
mode, concurrent workload and sample data with any reported result. Retain the
result bundle, including XCTest's launch measurements and the JSON attachment.

## Observed simulator run — 2026-11-06

One idle Release run on an iPhone 18 Pro simulator (iOS 27.2), hosted by a
MacBook Pro M1 Max (32 GB, macOS 26.6.2, Xcode 27.2), loaded the persisted
1,000-garment fixture and verified the visible 40-item first page. XCTest's
`ApplicationFirstFramePresentationResponsive` metric averaged 4.748 s across
20 samples (nearest-rank p95 4.823 s, max 4.861 s). The separate launch-to-
visible-page measurement had nearest-rank p95 7.214 s and max 7.265 s; it
includes XCTest launch/query overhead and fixture validation. Raw samples and
conditions are in
[`T059-wardrobe-launch-2026-11-06.json`](T059-wardrobe-launch-2026-11-06.json).
These simulator results do **not** establish the physical-device ≤2 s launch
acceptance target.

## Isolation and remaining acceptance

Both the route and test require `WARDROBE_BENCHMARK` **and** a simulator build.
No normal build configuration defines this flag, and a physical-device build
cannot include the route. The fixture uses a dedicated `LaunchBenchmark`
directory, no session, no account credentials, and a remote that always returns
an offline error. It does not send email, access the gateway, enable AI, or
download photos. Missing or malformed fixtures fail instead of measuring an
empty screen.

This is a cached-wardrobe baseline, not authenticated end-to-end acceptance.
T059 remains open for the named physical-device launch budget, authenticated
API/network timings and live AI latency under the intended
conditions. The existing SQLite and PostgreSQL timings remain separate in
[T059-performance.md](T059-performance.md).
