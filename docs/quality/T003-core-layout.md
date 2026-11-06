# T003 — core-screen layout verification

At the largest accessibility text size, the Debug preview's persistent disclosure
occupied much of the screen. The visible banner now uses a short localized
“Offline demo” label without limiting Dynamic Type. The full disclosure remains
available to VoiceOver and in the localized About tab. Preview data and edits
remain local and do not imply a working server or AI service.

The shortcut's wear-confirmation screen also referenced two missing catalog keys.
`widget.chooseOutfit` and `widget.confirmTitle` now have Polish and English values.
The catalog change adds these two keys and nine preview strings; existing
translations are unchanged.

## Executed scope

`CoreLayoutAccessibilityTests` opens the existing Debug-only demo and uses the
production wardrobe, garment detail and outfit-editor views. It scrolls to a
garment, changes its archive state, opens a new outfit, enters a long name,
selects a garment, saves, and checks that the saved name is visible. Each run
attaches screenshots of the wardrobe, status control, save action and saved card.
The repository is in memory; this is a UI/layout check, not backend acceptance.

All four language/appearance combinations passed on the iOS 27.2 Simulator at
`accessibility-extra-extra-extra-large` (AX5), 402 × 874 points: Polish-light,
English-light, Polish-dark and English-dark. Representative screenshots across
the matrix were inspected. They show the localized compact banner, status control,
Save/Cancel actions and wrapped outfit name remaining reachable; this does not
claim that every attachment or screen was visually inspected.

The resource check passes with 695 PL/EN catalog keys and a minimum text contrast
of 6.68:1 across its declared light/dark token pairs. Resource validation is not
a substitute for inspecting rendered screens.

## Reproduction and limits

Use the `MojaSzafaUI` scheme in Debug and select only
`MojaSzafaUITests/CoreLayoutAccessibilityTests`. Set the chosen dedicated
simulator's content size to `accessibility-extra-extra-extra-large` and its
appearance to the intended light/dark mode before launching. Each test sets the
application language and locale explicitly. Restore the simulator's previous
settings after the run.

These cases do not cover every authenticated screen, all device sizes or
orientations, physical-device VoiceOver, or the complete T057 matrix. T003 and
T057 remain open for their remaining coverage; the missing-string and preview
layout fixes do not imply full application accessibility acceptance.
