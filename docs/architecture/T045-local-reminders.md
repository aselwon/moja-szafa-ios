# T045 — Local reminders

Profile → Reminders provides separate opt-ins for planned outfits and recording wear, hourly delivery settings, and quiet hours. Defaults are off. Only Save with an enabled opt-in requests notification permission. Denial leaves wardrobe, outfits, planning and manual wear recording available; Settings provides a route to the system permission controls.

Plan notifications refer to actual, non-deleted, unconfirmed plans fetched across all pages. Wear reminders are an explicitly selected daily reminder, not a claim that an outfit was worn. Notification content is generic and contains no garment names, photos, email or credentials. A tap checks the active account/gateway scope before opening the plan date or saved outfits. Existing wear confirmation remains mandatory. It never records wear automatically.

## Scheduling and cancellation

The schedule covers the next 14 calendar days and contains at most 60 pending notifications. This bounded horizon is explained in the UI. Plans retain their stored timezone; quiet hours use the current device timezone. Calendar arithmetic handles short/long DST days and nonexistent hours using the next available local time. The first occurrence is chosen for repeated hours. Each resulting request uses an explicit UTC instant.

Opening/foregrounding the app, significant clock changes and timezone notifications rebuild the horizon. Local plan mutations cancel the schedule immediately, then fetch authoritative plans after completion, including ambiguous responses. A failed refresh leaves no stale schedule and displays an error. Changes made on another device require reopening this app. When iOS suspends or terminates the app, no continuous network fetch or timezone recalculation is promised; existing requests retain their scheduled instants until the app runs again. There is no APNs service or background-execution claim.

Logout, expiry, account deletion and account/gateway switching clear pending and delivered notifications. Settings are protected, excluded from backup, scoped by account and gateway, retained over an authenticated relaunch and removed when leaving that account. Request identifiers include a unique scheduling generation. Delayed notification adds clean up their own generation, so an in-flight old-account request cannot reappear after logout or remove a newer schedule.

## Verification

Focused XCTest coverage exercises opt-out, denied permission, spring/fall DST, daytime/overnight quiet hours, stored plan timezones, deleted/confirmed/duplicate plans, the horizon and pending limit, persisted settings, logout during an in-flight add, scope/date validation of taps, planner pagination, failure cancellation, and mutation rescheduling. Existing Planner and Authentication tests are run alongside these tests.

Actual permission prompts, lock-screen delivery, cold launch via a notification, timezone changes while the app is suspended, and VoiceOver on a physical iPhone still require device validation. Simulator/unit tests are not reported as proof of physical delivery. This feature does not require provisioning a paid push-notification service.
