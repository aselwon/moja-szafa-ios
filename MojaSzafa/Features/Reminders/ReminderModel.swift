import Combine
import CryptoKit
import Foundation
import UserNotifications

struct ReminderSettings: Codable, Equatable, Sendable {
    var plans = false
    var wear = false
    var planHour = 8
    var wearHour = 20
    var quietStart = 22
    var quietEnd = 8
    var enabled: Bool { plans || wear }
    var valid: Bool { [planHour, wearHour, quietStart, quietEnd].allSatisfy { (0...23).contains($0) } && quietStart != quietEnd }
}

struct ReminderRequest: Equatable, Sendable {
    enum Kind: String, Sendable { case plan, wear }
    let id: String
    let kind: Kind
    let date: Date
    let day: String
    let timezone: String
    let scope: String
}

struct ReminderRoute: Identifiable {
    let id = UUID()
    let kind: ReminderRequest.Kind
    let day: String
    let timezone: String
}

/// A bounded rolling horizon; dates are calendar additions, never 86,400-second days.
/// Plans retain their recorded timezone. Quiet hours follow the device timezone.
enum ReminderSchedule {
    static func requests(plans: [PlannedOutfit], settings: ReminderSettings, now: Date,
                         timezone: TimeZone, scope: String, generation: UUID) -> [ReminderRequest] {
        guard settings.valid else { return [] }
        var local = Calendar(identifier: .gregorian); local.timeZone = timezone
        guard let end = local.date(byAdding: .day, value: 14, to: local.startOfDay(for: now)) else { return [] }
        var result: [ReminderRequest] = []
        func append(_ date: Date, kind: ReminderRequest.Kind, day: String, zone: String, key: String) {
            let adjusted = outsideQuietHours(date, settings: settings, calendar: local)
            guard adjusted > now, adjusted < end else { return }
            result.append(ReminderRequest(id: "szafa.reminder.\(generation).\(key)", kind: kind,
                date: adjusted, day: day, timezone: zone, scope: scope))
        }
        if settings.wear {
            for offset in 0..<14 {
                guard let day = local.date(byAdding: .day, value: offset, to: local.startOfDay(for: now)),
                      let date = local.date(bySettingHour: settings.wearHour, minute: 0, second: 0, of: day,
                                            matchingPolicy: .nextTime, repeatedTimePolicy: .first, direction: .forward) else { continue }
                append(date, kind: .wear, day: PlannerDay.string(day, timezone: timezone.identifier), zone: timezone.identifier, key: "wear.\(offset)")
            }
        }
        if settings.plans {
            var seen = Set<UUID>()
            for plan in plans where !plan.deleted && plan.wearID == nil && seen.insert(plan.id).inserted {
                guard let zone = TimeZone(identifier: plan.timezone), let day = parseDay(plan.day, timezone: zone) else { continue }
                var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
                guard let date = calendar.date(bySettingHour: settings.planHour, minute: 0, second: 0, of: day,
                                               matchingPolicy: .nextTime, repeatedTimePolicy: .first, direction: .forward) else { continue }
                append(date, kind: .plan, day: plan.day, zone: zone.identifier, key: plan.id.uuidString)
            }
        }
        // Leave room below the OS pending-notification ceiling. UI explains the horizon.
        return Array(result.sorted { ($0.date, $0.id) < ($1.date, $1.id) }.prefix(60))
    }

    static func parseDay(_ value: String, timezone: TimeZone) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian); formatter.timeZone = timezone
        formatter.dateFormat = "yyyy-MM-dd"; formatter.isLenient = false
        guard let date = formatter.date(from: value), formatter.string(from: date) == value else { return nil }
        return date
    }

    static func outsideQuietHours(_ date: Date, settings: ReminderSettings, calendar: Calendar) -> Date {
        let hour = calendar.component(.hour, from: date)
        let quiet = settings.quietStart < settings.quietEnd
            ? hour >= settings.quietStart && hour < settings.quietEnd
            : hour >= settings.quietStart || hour < settings.quietEnd
        guard quiet else { return date }
        return calendar.nextDate(after: date, matching: DateComponents(hour: settings.quietEnd, minute: 0, second: 0),
                                 matchingPolicy: .nextTime, repeatedTimePolicy: .first, direction: .forward) ?? date
    }
}

@MainActor
protocol ReminderNotificationCenter: AnyObject {
    func authorized() async -> Bool
    func requestPermission() async throws -> Bool
    func clear()
    func remove(_ identifiers: [String])
    func add(_ request: ReminderRequest) async throws
}

@MainActor
final class SystemReminderCenter: NSObject, ReminderNotificationCenter, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()
    var tapped: ((String, String, String, String) -> Void)?
    override init() { super.init(); center.delegate = self }
    func authorized() async -> Bool {
        let status = await center.notificationSettings().authorizationStatus
        return status == .authorized || status == .provisional || status == .ephemeral
    }
    func requestPermission() async throws -> Bool { try await center.requestAuthorization(options: [.alert, .sound]) }
    // This application owns no other notification producers. Clearing delivered
    // content as well prevents old-account taps after logout.
    func clear() { center.removeAllPendingNotificationRequests(); center.removeAllDeliveredNotifications() }
    func remove(_ identifiers: [String]) { center.removePendingNotificationRequests(withIdentifiers: identifiers) }
    func add(_ request: ReminderRequest) async throws {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "reminders.notificationTitle")
        content.body = request.kind == .plan ? String(localized: "reminders.planBody") : String(localized: "reminders.wearBody")
        content.sound = .default
        content.userInfo = ["scope": request.scope, "kind": request.kind.rawValue, "day": request.day, "timezone": request.timezone]
        // An explicit UTC instant preserves the computed quiet-hour/DST decision.
        // Foreground/timezone changes replace the bounded pending schedule.
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = .gmt
        var components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: request.date)
        components.timeZone = .gmt
        try await center.add(UNNotificationRequest(identifier: request.id, content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)))
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier,
           let scope = info["scope"] as? String, let kind = info["kind"] as? String,
           let day = info["day"] as? String, let timezone = info["timezone"] as? String {
            Task { @MainActor [weak self] in self?.tapped?(scope, kind, day, timezone) }
        }
        completionHandler()
    }
}

@MainActor
final class ReminderModel: ObservableObject {
    @Published private(set) var settings = ReminderSettings()
    @Published private(set) var busy = false
    @Published private(set) var errorKey: String?
    @Published private(set) var scheduledCount = 0
    @Published var route: ReminderRoute?
    private let center: any ReminderNotificationCenter
    private var scope: String?
    private var settingsURL: URL?
    private var repository: (any PlannerRepository)?
    private var generation = UUID()
    private var pendingTap: (String, String, String, String)?
    private var initialized = false
    private var sessionRevision = UUID()
    private var mutationInFlight = false

    init(center: any ReminderNotificationCenter) { self.center = center }
    static func live() -> ReminderModel {
        let center = SystemReminderCenter()
        let model = ReminderModel(center: center)
        center.tapped = { [weak model] in model?.receive(scope: $0, kind: $1, day: $2, timezone: $3) }
        return model
    }

    func sessionChanged(accountID: UUID?, gateway: String, repository: any PlannerRepository, directory: URL = .applicationSupportDirectory) {
        let next = accountID.map { SHA256.hash(data: Data("\(gateway)/\($0.uuidString)".utf8)).map { String(format: "%02x", $0) }.joined() }
        guard !initialized || next != scope else { return }
        initialized = true; sessionRevision = UUID()
        generation = UUID(); center.clear(); route = nil; scheduledCount = 0; busy = false; mutationInFlight = false
        if let previous = settingsURL, scope != nil { try? FileManager.default.removeItem(at: previous) }
        scope = next; self.repository = accountID == nil ? nil : repository
        settingsURL = next.map { directory.appendingPathComponent("Reminders").appendingPathComponent($0 + ".json") }
        settings = ReminderSettings(); errorKey = nil
        if let settingsURL, FileManager.default.fileExists(atPath: settingsURL.path) {
            do {
                let value = try JSONDecoder().decode(ReminderSettings.self, from: Data(contentsOf: settingsURL))
                guard value.valid else { throw APIClientError.invalidResponse }; settings = value
            } catch { errorKey = "reminders.storage" }
        }
        if let tap = pendingTap, next != nil {
            pendingTap = nil; receive(scope: tap.0, kind: tap.1, day: tap.2, timezone: tap.3)
        }
        if settings.enabled { Task { await refresh() } }
    }

    func apply(_ value: ReminderSettings) async {
        guard !busy, value.valid, let scope, let settingsURL else { return }
        busy = true; errorKey = nil
        let operation = sessionRevision
        defer { if sessionRevision == operation { busy = false } }
        do {
            if value.enabled, !(await center.authorized()) {
                guard try await center.requestPermission() else {
                    if sessionRevision == operation { cancelPending(); errorKey = "reminders.denied" }; return
                }
            }
            guard sessionRevision == operation, self.scope == scope else { return }
            try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            var excluded = URLResourceValues(); excluded.isExcludedFromBackup = true
            var folder = settingsURL.deletingLastPathComponent(); try folder.setResourceValues(excluded)
            try JSONEncoder().encode(value).write(to: settingsURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            settings = value
            await refresh()
        } catch { if sessionRevision == operation { errorKey = "reminders.failed" } }
    }

    func cancelPending() { generation = UUID(); center.clear(); scheduledCount = 0 }
    func planMutationStarted() { mutationInFlight = true; cancelPending() }
    func planMutationFinished() { mutationInFlight = false; Task { await refresh() } }

    func refresh(now: Date = Date(), timezone: TimeZone = .current) async {
        cancelPending()
        guard let scope, let repository, settings.enabled, !mutationInFlight else { return }
        let operation = generation
        let value = settings
        var added: [String] = []
        do {
            guard await center.authorized() else { if generation == operation { errorKey = "reminders.denied" }; return }
            guard generation == operation else { return }
            var plans: [PlannedOutfit] = []
            if value.plans {
                var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timezone
                let from = calendar.date(byAdding: .day, value: -1, to: now) ?? now
                let through = calendar.date(byAdding: .day, value: 15, to: now) ?? now
                var cursor: UUID?
                var seen = Set<UUID>()
                repeat {
                    let page = try await repository.plans(from: PlannerDay.string(from, timezone: timezone.identifier),
                        through: PlannerDay.string(through, timezone: timezone.identifier), cursor: cursor)
                    guard generation == operation else { return }
                    plans += page.items; cursor = page.nextCursor
                    if let cursor, !seen.insert(cursor).inserted || seen.count > 100 { throw APIClientError.invalidResponse }
                } while cursor != nil
            }
            let requests = ReminderSchedule.requests(plans: plans, settings: value, now: now, timezone: timezone, scope: scope, generation: operation)
            for request in requests {
                guard generation == operation else { center.remove(added); return }
                added.append(request.id)
                try await center.add(request)
                guard generation == operation else { center.remove(added); return }
            }
            scheduledCount = requests.count; errorKey = nil
        } catch {
            center.remove(added)
            if generation == operation { scheduledCount = 0; errorKey = "reminders.failed" }
        }
    }

    func receive(scope: String, kind: String, day: String, timezone: String) {
        guard let kindValue = ReminderRequest.Kind(rawValue: kind), let zone = TimeZone(identifier: timezone),
              ReminderSchedule.parseDay(day, timezone: zone) != nil else { return }
        guard initialized, self.scope != nil else { pendingTap = (scope, kind, day, timezone); return }
        guard self.scope == scope else { return }
        route = ReminderRoute(kind: kindValue, day: day, timezone: timezone)
    }
}
