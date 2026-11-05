import AppIntents

struct WardrobeShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ConfirmWearIntent(), phrases: ["Confirm wear in \(.applicationName)"],
                    shortTitle: "widget.shortcutTitle", systemImageName: "checkmark.circle")
    }
}
