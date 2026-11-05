# T046 — Today widget and explicit wear confirmation

The WidgetKit extension supports small and medium home-screen widgets. Profile → Widget offers an explicit opt-in for sharing only today's count of unconfirmed planned outfits. The shared JSON contains the count, day/timezone and freshness timestamps. It contains no credentials, account identifiers, garment/outfit names, photos, prices or garment IDs. No network client, auth store or API token is linked into the extension.

Development, staging and production use separate bundle IDs, URL schemes and App Groups. The widget has only the App Group entitlement; Sign in with Apple remains on the main app. Registering these identifiers and signing for physical distribution requires the publisher's Apple Developer account. The app detects an unavailable shared container and does not pretend the widget opt-in succeeded.

## Freshness and privacy

The app fetches all pages of today's plans, excludes deleted/confirmed plans and deduplicates IDs before writing a protected, backup-excluded aggregate. Snapshots expire after at most 15 minutes or at local midnight, whichever comes first. Widget timelines include an empty entry at expiry; invalid, expired, wrong-timezone, oversized or corrupt files render the open-app message. Plan counts and update times are marked privacy-sensitive. The extension never refetches account data on its own.

Foreground, clock/timezone changes and local planner mutations refresh the snapshot. Remote edits require opening the app. Logout/account changes clear the shared file and request a WidgetKit timeline reload. Late network responses are fenced by a generation and cannot restore a previous account's snapshot. Turning off the option works even while a network read is suspended. WidgetKit controls actual screen redraw timing: clearing the file and requesting reload are not a guarantee of instantaneous removal of an already-rendered OS snapshot. This is one reason the widget deliberately never renders identifying wardrobe content.

## Confirmation routing

The widget button and Shortcuts action use `ConfirmWearIntent` with `openAppWhenRun = true`, supported on iOS 17. Apple documents that this executes in the app process. It sets only a pending in-memory navigation request; it performs no wear mutation. The URL fallback accepts only the current environment's exact `://wear` route, without parameters, user information, port or fragment. Unauthenticated users must pass the normal authentication and profile gates.

The app opens a dedicated Today confirmation screen. The person selects a plan and reviews its outfit name, date and timezone in a confirmation dialog before the existing versioned/idempotent planner confirmation API is called. Choosing another saved outfit leads to the existing explicit wear flow. The widget and intent cannot confirm a plan in the background or bypass authentication.

## Verification boundary

Native tests cover the shared payload allowlist, storage round trips/erasure, malformed and expired snapshots, timezone/clock validation, URL validation, paginated counts, opt-out during a suspended request, logout during a suspended request, and an actual intent invocation that queues UI without reading or writing wardrobe data. Builds must include the embedded extension in Debug, Staging and Release.

A signed physical-device pass is still required for adding the widget to SpringBoard, locked-screen privacy/redaction, Siri/Shortcuts discovery, cold launch and redraw timing after logout. Unit tests and simulator builds are not reported as proof of those physical-device behaviors.

References:
- [Apple: adding interactivity to widgets](https://developer.apple.com/documentation/widgetkit/adding-interactivity-to-widgets-and-live-activities)
- [Apple: keeping a widget up to date](https://developer.apple.com/documentation/widgetkit/keeping-a-widget-up-to-date/)
- [Apple: linking widgets to app scenes](https://developer.apple.com/documentation/widgetkit/linking-to-specific-app-scenes-from-your-widget-or-live-activity)

## Local verification evidence (2026-11-05)

- App and embedded widget Debug build passed; repository harness passed 63/63.
- Focused native suite passed 41/41: Widget 9, Planner 7, Reminder 12, Authentication 13, no skips or failures.
- An additional shared-container integration test passed 1/1 with no skips using Xcode's local ad hoc simulator signing. It wrote, read and cleared the real configured App Group container. Both app and extension simulator-effective entitlement files matched `group.pl.mojaszafa.app.dev`. This used no Apple account, provisioning profile or provisioning update.
- The shared-container test explicitly skips in unsigned test hosts; its successful signed run is separate evidence, not inferred from an unsigned CI result. Physical-device and actual widget-screen validation remain the boundary described above.
