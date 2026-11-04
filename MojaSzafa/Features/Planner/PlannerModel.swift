import Combine
import Foundation

struct PlannedOutfit: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let version: Int64
    let day: String
    let timezone: String
    let deleted: Bool
    let outfit: Outfit
    let wearID: UUID?

    var canConfirm: Bool { !deleted && wearID == nil && day <= PlannerDay.string(Date(), timezone: timezone) }
}

enum PlannerDay {
    static func string(_ date: Date, timezone: String = TimeZone.current.identifier) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: timezone) ?? .gmt
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

struct PlannerMutation: Codable, Equatable, Sendable {
    enum Action: String, Codable, Sendable { case create, move, delete, restore, confirm }
    let action: Action
    var operationID = UUID()
    let id: UUID
    let baseVersion: Int64
    var outfitVersion: Int64?
    var outfitID: UUID?
    var day: String?
    var timezone: String?
}

struct PlannerPage: Decodable, Sendable {
    let items: [PlannedOutfit]
    let nextCursor: UUID?
}

protocol PlannerRepository: Sendable {
    func plans(from: String, through: String, cursor: UUID?) async throws -> PlannerPage
    func changePlan(_ request: PlannerMutation) async throws -> PlannedOutfit
}
struct UnconfiguredPlannerRepository: PlannerRepository {
    func plans(from: String, through: String, cursor: UUID?) async throws -> PlannerPage { throw RepositoryError.backendNotConfigured }
    func changePlan(_ request: PlannerMutation) async throws -> PlannedOutfit { throw RepositoryError.backendNotConfigured }
}
extension APIClient: PlannerRepository {
    func plans(from: String, through: String, cursor: UUID?) async throws -> PlannerPage {
        struct Query: Encodable { let action = "list"; let from: String; let through: String; let cursor: UUID? }
        let response: APIv1.Success<PlannerPage> = try await call("api_v1_planner", Query(from: from, through: through, cursor: cursor))
        return response.data
    }
    func changePlan(_ request: PlannerMutation) async throws -> PlannedOutfit {
        let response: APIv1.Success<PlannedOutfit> = try await call("api_v1_planner", request)
        guard response.data.id == request.id, response.data.version > 0 else { throw APIClientError.invalidResponse }
        return response.data
    }
}

/// One model is shared by Today and Outfits. An ambiguous intent is written
/// before sending, scoped to the authenticated account and gateway by composition.
@MainActor
final class PlannerModel: ObservableObject {
    @Published private(set) var items: [PlannedOutfit] = []
    @Published private(set) var nextCursor: UUID?
    @Published private(set) var loading = false
    @Published private(set) var saving = false
    @Published private(set) var errorKey: String?
    @Published private(set) var pending: PlannerMutation?
    @Published private(set) var undo: PlannerMutation?
    private let repository: any PlannerRepository
    private let journalURL: URL?
    private var loadID = UUID()
    private var revision = 0
    private var journalFailed = false
    private var range: (String, String)?

    init(repository: any PlannerRepository, journalURL: URL? = nil) {
        self.repository = repository; self.journalURL = journalURL
        if let journalURL, FileManager.default.fileExists(atPath: journalURL.path) {
            do { pending = try JSONDecoder().decode(PlannerMutation.self, from: Data(contentsOf: journalURL)) }
            catch { journalFailed = true; errorKey = "planner.journalFailed" }
        }
    }

    func load(from: String, through: String, more: Bool = false) async {
        if more && (loading || nextCursor == nil || range?.0 != from || range?.1 != through) { return }
        let cursor = more ? nextCursor : nil
        let id = UUID()
        loadID = id
        range = (from, through); loading = true
        // Hide the preceding range while the newly selected week loads.
        if !more { items = []; nextCursor = nil }
        let revision = self.revision
        defer { if loadID == id { loading = false } }
        if !journalFailed { errorKey = nil }
        do {
            let values = try await repository.plans(from: from, through: through, cursor: cursor)
            try Task.checkCancellation()
            guard loadID == id, revision == self.revision else { return }
            if more {
                let existing = Set(items.map(\.id))
                items += values.items.filter { !existing.contains($0.id) }
            } else { items = values.items }
            items.sort { ($0.day, $0.id.uuidString) < ($1.day, $1.id.uuidString) }
            nextCursor = values.nextCursor
        } catch {
            guard loadID == id, revision == self.revision else { return }
            setError(error)
        }
    }

    func change(_ request: PlannerMutation) async -> Bool {
        guard !saving, !journalFailed, pending == nil || pending == request else { return false }
        saving = true; errorKey = nil; revision += 1
        defer { saving = false }
        let original = items.first { $0.id == request.id }
        do {
            if pending == nil { try persist(request); pending = request }
            let saved = try await repository.changePlan(request)
            // Clear only after acknowledged completion. A disk failure keeps the
            // same operation available for replay, including across relaunch.
            try persist(nil); pending = nil; revision += 1
            items.removeAll { $0.id == saved.id }
            if !saved.deleted, range.map({ saved.day >= $0.0 && saved.day <= $0.1 }) ?? true { items.append(saved) }
            items.sort { ($0.day, $0.id.uuidString) < ($1.day, $1.id.uuidString) }
            switch request.action {
            case .delete: undo = PlannerMutation(action: .restore, id: saved.id, baseVersion: saved.version)
            case .create, .restore: undo = PlannerMutation(action: .delete, id: saved.id, baseVersion: saved.version)
            case .move:
                undo = original.map { PlannerMutation(action: .move, id: saved.id, baseVersion: saved.version, day: $0.day, timezone: $0.timezone) }
            case .confirm: undo = nil // Undoing a plan must never undo recorded history.
            }
            return true
        } catch {
            if let failure = error as? APIv1.Failure,
               ["validation_failed", "version_conflict", "account_unavailable", "idempotency_conflict"].contains(failure.code) {
                do { try persist(nil); pending = nil } catch { journalFailed = true }
                errorKey = failure.code == "version_conflict" ? "planner.conflict" : "planner.rejected"
            } else if error as? RepositoryError == .backendNotConfigured {
                do { try persist(nil); pending = nil } catch { journalFailed = true }
                errorKey = "foundation.serviceUnavailable"
            } else { setError(error) }
            return false
        }
    }

    func retry() async { if let pending { _ = await change(pending) } }
    func undoLast() async { if let undo { _ = await change(undo) } }

    private func persist(_ request: PlannerMutation?) throws {
        guard let journalURL else { return }
        if let request {
            try FileManager.default.createDirectory(at: journalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(request).write(to: journalURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } else if FileManager.default.fileExists(atPath: journalURL.path) { try FileManager.default.removeItem(at: journalURL) }
    }
    private func setError(_ error: any Error) {
        if journalFailed { errorKey = "planner.journalFailed" }
        else if error as? RepositoryError == .backendNotConfigured { errorKey = "foundation.serviceUnavailable" }
        else if error is URLError { errorKey = "planner.offline" }
        else if !(error is CancellationError) { errorKey = "foundation.loadFailed" }
    }
}
