# T014 — Onboarding and profile

The first-launch welcome screen explains wardrobe, outfit planning and wear history before authentication or any purchase UI. A clearly labeled fictional CPW example illustrates value without creating wardrobe records. Continue and Skip both lead to authentication. The welcome acknowledgement is device-wide and contains no personal preferences.

After authentication, an account-scoped gate offers optional styles, color families and outfit priorities. Save accepts empty selections; Skip discards unconfirmed selections and completes onboarding. Profile remains accessible above the tabs for editing or clearing choices. Cancel or dismiss discards unsaved edits. No gender, size, body photo, AI consent or purchase is requested. These style preferences do not grant AI consent.

Preferences and completion are stored atomically in Application Support/Profiles/<account UUID>.json with complete file protection. No network is required. A failed save keeps the draft visible and does not complete onboarding; retry uses the same draft. Failed decoding does not overwrite the existing file. Account changes recreate the feature model using the session UUID, so another account cannot see the prior account's selections through the UI.

## Limitations

This is explicitly device-local persistence, as disclosed on screen. It does not implement server profile synchronization or feed preferences into AI. The production authentication service is still unconfigured by the existing composition root (T013); authenticated flows require the existing injected authentication configuration. No account, cloud resource or provider was configured for this task. A successful login on a real device is not claimed.

The per-account file survives logout for return visits. Account deletion/export must include this directory when those lifecycle features are implemented. Complete file protection can temporarily prevent reads while the device is locked; unlocking and retrying should restore access. A corrupt file is preserved and reported, not silently reset.

## Verification

Run `node scripts/harness-check.mjs` for repository checks. `ProfileTests` is registered with the existing macOS CI test target and covers empty completion, skip, draft isolation, persistence, account isolation, failed-save retry and corrupt-data preservation. Linux structural validation is not a Swift build or XCTest execution.

On macOS run the existing CI scheme for Debug, Staging and Release. On simulator/device with an injected authenticated service:

1. Fresh install: verify PL/EN welcome text and the labeled CPW example appear before login and before any future paywall; Skip leads to login without purchase.
2. Sign in: finish with no selections, relaunch, and confirm onboarding stays completed. Repeat with selections and with Skip after changing a draft (changes must be discarded).
3. Open Profile, change and save all three groups, reopen; clear choices and save; cancel an edit and verify saved values remain unchanged.
4. Log out and switch accounts: the second account starts empty; return to the first account and verify its preferences. Repeat edits offline.
5. Check largest accessibility text sizes, VoiceOver toggle labels/values, dark mode and Reduce Motion in PL/EN. All controls must remain reachable by scrolling; no animation or permission prompt is needed.
6. Exercise storage failures through the unit tests and verify failed saves do not advance the gate. Record actual CI/device results; none are available from this sandbox.
