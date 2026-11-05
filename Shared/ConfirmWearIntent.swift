import AppIntents
import Foundation

/// openAppWhenRun executes this intent in the app process (including on iOS 17).
/// A pending in-memory route survives scene creation, not an application restart.
/// It is only a request to present UI; no data mutation or credential is involved.
@MainActor
enum WearIntentRoute {
    static let notification = Notification.Name("WardrobeOpenWearConfirmation")
    private(set) static var requested = false
    static func request() {
        requested = true
        NotificationCenter.default.post(name: notification, object: nil)
    }
    static func consume() -> Bool {
        guard requested else { return false }
        requested = false; return true
    }
}

struct ConfirmWearIntent: AppIntent {
    static var title: LocalizedStringResource { "widget.intentTitle" }
    static var description: IntentDescription { IntentDescription("widget.intentDescription") }
    static var openAppWhenRun: Bool { true }
    @MainActor func perform() async throws -> some IntentResult {
        WearIntentRoute.request()
        return .result()
    }
}
