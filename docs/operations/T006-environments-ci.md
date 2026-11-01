# T006 — Environments and CI

## Configuration

| Xcode configuration | Environment | App bundle ID | Display name | Device signing |
| --- | --- | --- | --- | --- |
| Debug | dev | pl.mojaszafa.app.dev | Moja Szafa Dev | Automatic / Apple Development |
| Staging | staging | pl.mojaszafa.app.staging | Moja Szafa Staging | Automatic / Apple Development |
| Release | prod | pl.mojaszafa.app | Moja Szafa | Manual / Apple Distribution |

These are repository identifiers, not evidence of Apple registrations. Separate
bundle IDs allow side-by-side installation and separate default app containers
and keychain access groups. No shared keychain/app groups are configured. Future
auth, storage, push and widget work must preserve this separation.

Each app target configuration references its own `Configuration/*.xcconfig`.
The generated Info.plist contains `AppEnvironment`. `MojaSzafa` runs/tests Debug;
`MojaSzafa-Staging` runs/tests Staging. Both schemes profile/archive Release.
Staging inherits Debug optimization/testability; Release remains optimized.

There is no provisioned backend or approved endpoint. `BACKEND_BASE_URL` is empty
in all three configurations, and the existing live repository explicitly reports
that the backend is not configured. The build phase validates the **resolved**
environment, bundle ID, plist environment and signing policy and rejects any
endpoint, including command-line and local xcconfig overrides. Release therefore
cannot silently connect to staging or a demo service. This is a temporary
fail-closed integration boundary, not a working production service. T007/T009
must replace the endpoint lock with reviewed, explicit per-environment HTTPS
allowlists and test rejection of cross-environment URLs before enabling the client.
Do not add a staging fallback when production configuration is missing.

## Signing without repository credentials

Simulator CI uses `CODE_SIGNING_ALLOWED=NO` and needs no Apple credentials. Device
signing is separate and has not been exercised. On an authorized Mac, the owner
must register the three IDs and obtain the required certificates/profiles. Keep
private keys in the Mac keychain or an approved secret store, never in git.

Optional, ignored local files are loaded last:

- `Configuration/Signing/Dev.local.xcconfig`
- `Configuration/Signing/Staging.local.xcconfig`
- `Configuration/Signing/Production.local.xcconfig`

Create the directory locally as needed. Set the actual `DEVELOPMENT_TEAM` in the
appropriate file. For production also set the real
`PROVISIONING_PROFILE_SPECIFIER` for the production App ID, matching the installed
Apple Distribution identity. No fictional values are supplied. Overrides of the
environment, bundle ID, signing style or endpoint are rejected by the build guard.
The production guard requires a team and explicit profile whenever signing is
allowed; Xcode validates that these match actual installed signing assets.

To verify production signing on that Mac:

```sh
xcodebuild archive -project MojaSzafa.xcodeproj -scheme MojaSzafa \
  -configuration Release -destination 'generic/platform=iOS' \
  -archivePath /tmp/MojaSzafa.xcarchive
codesign --verify --deep --strict /tmp/MojaSzafa.xcarchive/Products/Applications/MojaSzafa.app
```

Inspect the archived Info.plist for `AppEnvironment=prod`, production bundle ID
and no backend URL. Inspect the signature and embedded profile for the actual
production team, App ID and distribution policy. This command does not upload
or publish. Missing accounts, certificates and profiles remain owner dependencies;
no signing success, distribution readiness or Apple approval is claimed.

## CI and local verification

`.github/workflows/ci.yml` has a mandatory repository validation job, followed by
three independent build/test jobs on `macos-latest` with the runner's default
Xcode and the first available iPhone simulator (selected dynamically, because
runner images rotate Xcode and simulator versions). It fails if the project,
toolchain or simulator is missing. There is no
conditional success path for absent Xcode projects. Workflow permissions are
read-only; no signing credentials, provisioning downloads or cloud calls are used.

Every configuration runs XCTest, including the actual app bundle's environment
and identity check and the existing unconfigured-live-repository test. Release
tests enable testability only through the CI command; a separate production build
uses the ordinary Release settings. XCTest result bundles are retained for 14 days,
including on failure when available. Xcode is intentionally not pinned:
pinned versions disappear from runner images and break CI.

Run the offline check from the repository root:

```sh
node scripts/harness-check.mjs
```

It includes structural configuration checks, executable shell-guard tests for all
three environments, unsafe override and missing-signing rejection, and a local
secret scan. The scanner examines current tracked and unignored untracked files,
including tracked files matching ignore patterns. It detects private keys, common
provider tokens, credential URLs, literal secret assignments and credential file
names. Synthetic tests verify each rule. It prints only paths and rule names.
It does not scan git history or prove that every possible credential format is
absent. Ignored local signing files intentionally stay outside this repository scan.
If a real credential is found, remove it and have its owner revoke/rotate it;
do not add an exclusion to make validation pass.

For macOS reproduction, run the T005 simulator command with each
`-configuration Debug`, `-configuration Staging`, and `-configuration Release`;
add `ENABLE_TESTABILITY=YES` for Release XCTest and use unique derived-data/result
paths. Also run the ordinary Release build from T005 without that override.
Attach the actual CI run and `.xcresult` artifacts before claiming macOS success.

## Evidence and remaining verification

The offline harness passes in the Linux sandbox, including secret detection
self-tests and environment guard rejection tests. No dependencies were installed.
Xcode/Swift and an iOS simulator are unavailable here, and no GitHub CI execution
or Apple signing operation has been performed. Actual compilation, XCTest,
three-app installation and signed archive inspection require the macOS/owner
steps above. No backend environment has been provisioned as part of T006.
