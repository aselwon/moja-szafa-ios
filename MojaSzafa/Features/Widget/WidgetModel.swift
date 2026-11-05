import Combine
import CryptoKit
import Foundation
import WidgetKit

@MainActor
final class WardrobeWidgetModel: ObservableObject {
    @Published private(set) var enabled = false
    @Published private(set) var busy = false
    @Published private(set) var errorKey: String?
    @Published private(set) var plannedCount: Int?
    @Published var showWearConfirmation = false
    var available: Bool { store.available }
    private let store: WidgetSnapshotStore
    private let reload: @MainActor () -> Void
    private var preferenceURL: URL?
    private var scope: String?
    private var initialized = false
    private var repository: (any PlannerRepository)?
    private var generation = UUID()
    private var mutationInFlight = false

    init(store: WidgetSnapshotStore, reload: @escaping @MainActor () -> Void = {}) {
        self.store = store; self.reload = reload
    }
    static func live() -> WardrobeWidgetModel {
        WardrobeWidgetModel(store: .live()) { WidgetCenter.shared.reloadTimelines(ofKind: WardrobeWidgetIdentity.kind) }
    }
    func sessionChanged(accountID: UUID?, gateway: String, repository: any PlannerRepository, directory: URL = .applicationSupportDirectory) {
        let next = accountID.map { SHA256.hash(data: Data("\(gateway)/\($0.uuidString)".utf8)).map { String(format: "%02x", $0) }.joined() }
        guard !initialized || next != scope else { return }
        initialized = true
        if scope != nil {
            if let preferenceURL { try? FileManager.default.removeItem(at: preferenceURL) }
            _ = WearIntentRoute.consume()
        }
        invalidate(); showWearConfirmation = false; mutationInFlight = false; busy = false
        scope = next; self.repository = accountID == nil ? nil : repository
        preferenceURL = next.map { directory.appendingPathComponent("WidgetPreferences").appendingPathComponent($0 + ".json") }
        enabled = false
        if let preferenceURL, FileManager.default.fileExists(atPath: preferenceURL.path) {
            do { enabled = try JSONDecoder().decode(Bool.self, from: Data(contentsOf: preferenceURL)) }
            catch { errorKey = "widget.storage" }
        }
        consumeIntent()
        if enabled { Task { await refresh() } }
    }
    func setEnabled(_ value: Bool) async {
        guard let preferenceURL, scope != nil, !busy || !value else { return }
        if value && !available { errorKey = "widget.unavailable"; return }
        do {
            var folder = preferenceURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var resource = URLResourceValues(); resource.isExcludedFromBackup = true
            try folder.setResourceValues(resource)
            try JSONEncoder().encode(value).write(to: preferenceURL, options: [.atomic, .completeFileProtection])
            enabled = value; errorKey = nil
            await refresh()
        } catch { errorKey = "widget.storage" }
    }
    func invalidate() {
        generation = UUID(); plannedCount = nil; busy = false
        do { try store.clear() }
        catch { errorKey = "widget.clearFailed" }
        reload()
    }
    func planMutationStarted() { mutationInFlight = true; invalidate() }
    func planMutationFinished() { mutationInFlight = false; Task { await refresh() } }
    func refresh(now: Date = Date(), timezone: TimeZone = .current) async {
        invalidate()
        guard enabled, scope != nil, let repository, !mutationInFlight else { return }
        guard available else { errorKey = "widget.unavailable"; return }
        let operation = generation
        busy = true
        defer { if generation == operation { busy = false } }
        do {
            let day = WardrobeWidgetSnapshot.dayString(now, timezone: timezone)
            var ids = Set<UUID>(); var cursors = Set<UUID>(); var cursor: UUID?
            repeat {
                let page = try await repository.plans(from: day, through: day, cursor: cursor)
                guard generation == operation else { return }
                for plan in page.items where plan.day == day && !plan.deleted && plan.wearID == nil { ids.insert(plan.id) }
                cursor = page.nextCursor
                if let cursor, !cursors.insert(cursor).inserted || cursors.count > 100 { throw APIClientError.invalidResponse }
            } while cursor != nil
            guard generation == operation, ids.count <= 10_000 else { throw APIClientError.invalidResponse }
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timezone
            let midnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now.addingTimeInterval(900)
            let snapshot = WardrobeWidgetSnapshot(version: 1, day: day, timezone: timezone.identifier, plannedCount: ids.count,
                generatedAt: now, expiresAt: min(now.addingTimeInterval(900), midnight))
            try store.write(snapshot)
            plannedCount = ids.count; errorKey = nil; reload()
        } catch {
            if generation == operation {
                try? store.clear(); plannedCount = nil; errorKey = "widget.failed"; reload()
            }
        }
    }
    func consumeIntent() {
        guard scope != nil, WearIntentRoute.consume() else { return }
        showWearConfirmation = true
    }
    func open(_ url: URL, expectedScheme: String) {
        guard WardrobeWidgetIdentity.accepts(url, expectedScheme: expectedScheme) else { return }
        WearIntentRoute.request(); consumeIntent()
    }
}
