import Foundation

/// Deliberately contains no credentials, account identifiers, outfit names, images,
/// garment IDs or prices. The app writes an opt-in, short-lived aggregate only.
struct WardrobeWidgetSnapshot: Codable, Equatable, Sendable {
    let version: Int
    let day: String
    let timezone: String
    let plannedCount: Int
    let generatedAt: Date
    let expiresAt: Date

    func isUsable(now: Date, timezone: TimeZone) -> Bool {
        guard version == 1, (0...10_000).contains(plannedCount), self.timezone == timezone.identifier,
              generatedAt <= now.addingTimeInterval(60), expiresAt > now,
              expiresAt > generatedAt, expiresAt.timeIntervalSince(generatedAt) <= 900 else { return false }
        return day == Self.dayString(now, timezone: timezone)
    }
    static func dayString(_ date: Date, timezone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = timezone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

struct WidgetSnapshotStore: Sendable {
    let directory: URL?
    var available: Bool { directory != nil }
    private var file: URL? { directory?.appendingPathComponent("today-widget-v1.json") }

    static func live(bundle: Bundle = .main) -> WidgetSnapshotStore {
        guard let group = bundle.object(forInfoDictionaryKey: "AppGroupIdentifier") as? String,
              group.hasPrefix("group.pl.mojaszafa.app"), !group.contains("$(") else { return WidgetSnapshotStore(directory: nil) }
        return WidgetSnapshotStore(directory: FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group))
    }
    func read(now: Date = Date(), timezone: TimeZone = .current) -> WardrobeWidgetSnapshot? {
        guard let file, let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 16_384,
              let data = try? Data(contentsOf: file), let value = try? JSONDecoder().decode(WardrobeWidgetSnapshot.self, from: data),
              value.isUsable(now: now, timezone: timezone) else { return nil }
        return value
    }
    func write(_ snapshot: WardrobeWidgetSnapshot) throws {
        guard let directory, let file else { throw CocoaError(.fileNoSuchFile) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(snapshot).write(to: file, options: [.atomic, .completeFileProtection])
        var resource = URLResourceValues(); resource.isExcludedFromBackup = true
        var url = file; try url.setResourceValues(resource)
    }
    func clear() throws {
        guard let file else { return }
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
    }
}

enum WardrobeWidgetIdentity {
    static let kind = "WardrobeToday"
    static func wearURL(bundle: Bundle = .main) -> URL? {
        guard let scheme = bundle.object(forInfoDictionaryKey: "AppURLScheme") as? String,
              ["mojaszafa-dev", "mojaszafa-staging", "mojaszafa"].contains(scheme) else { return nil }
        return URL(string: "\(scheme)://wear")
    }
    static func accepts(_ url: URL, expectedScheme: String) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        return components.scheme == expectedScheme && components.host == "wear" && components.path.isEmpty
            && components.query == nil && components.fragment == nil && components.user == nil && components.password == nil && components.port == nil
    }
}
