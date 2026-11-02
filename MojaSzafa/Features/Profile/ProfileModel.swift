import Foundation
import Observation

struct ProfilePreferences: Codable, Equatable {
    var styles: Set<String> = []
    var colors: Set<String> = []
    var priorities: Set<String> = []
    var onboardingCompleted = false

    static let styles = ["casual", "classic", "sporty", "minimal"]
    static let colors = ["neutral", "bright", "pastel", "dark"]
    static let priorities = ["comfort", "layers", "repeat"]
}

/// Device-local preferences, isolated by authenticated account UUID. This is not
/// a server sync implementation and must not be represented as one in the UI.
struct ProfileStore {
    let directory: URL

    static var local: ProfileStore {
        ProfileStore(directory: URL.applicationSupportDirectory.appendingPathComponent("Profiles", isDirectory: true))
    }

    private func url(for accountID: UUID) -> URL {
        directory.appendingPathComponent(accountID.uuidString).appendingPathExtension("json")
    }

    func remove(accountID: UUID) throws {
        let file = url(for: accountID)
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
    }

    func load(accountID: UUID) throws -> ProfilePreferences {
        let file = url(for: accountID)
        guard FileManager.default.fileExists(atPath: file.path) else { return ProfilePreferences() }
        return try JSONDecoder().decode(ProfilePreferences.self, from: Data(contentsOf: file))
    }

    func save(_ preferences: ProfilePreferences, accountID: UUID) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(preferences).write(to: url(for: accountID), options: [.atomic, .completeFileProtection])
    }
}

@MainActor @Observable
final class ProfileModel {
    private(set) var saved = ProfilePreferences()
    private(set) var loaded = false
    private(set) var message: String?
    private let accountID: UUID
    private let store: ProfileStore

    init(accountID: UUID, store: ProfileStore = .local) {
        self.accountID = accountID
        self.store = store
    }

    func load() {
        do {
            saved = try store.load(accountID: accountID)
            loaded = true
            message = nil
        } catch { message = "profile.loadError" }
    }

    @discardableResult
    func save(_ draft: ProfilePreferences) -> Bool {
        guard loaded else { return false }
        do {
            try store.save(draft, accountID: accountID)
            saved = draft
            message = nil
            return true
        } catch {
            message = "profile.saveError"
            return false
        }
    }

    func finish(_ draft: ProfilePreferences, skipping: Bool = false) {
        var next = skipping ? saved : draft
        next.onboardingCompleted = true
        save(next)
    }
}

struct AIDisclosure: Codable, Equatable, Sendable {
    let policy_version: String
    let recipient: String
    let data_description: String
    let purpose_description: String
}

struct AIConsentSnapshot: Decodable, Sendable {
    let disclosure: AIDisclosure?
    let granted: Bool
}

struct AIConsentChoice: Encodable, Sendable {
    let operation_id: UUID
    let granted: Bool
    let disclosure: AIDisclosure?

    enum CodingKeys: String, CodingKey { case operation_id, granted, disclosure }
    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(operation_id, forKey: .operation_id)
        try c.encode(granted, forKey: .granted)
        try c.encode(disclosure, forKey: .disclosure)
    }
}

protocol AIConsentService: Sendable {
    func consent() async throws -> AIConsentSnapshot
    func choose(_ choice: AIConsentChoice) async throws -> AIConsentSnapshot
}

extension APIClient: AIConsentService {
    func consent() async throws -> AIConsentSnapshot {
        let response: APIv1.Success<AIConsentSnapshot> = try await call("api_v1_ai_consent", [String: String]())
        return response.data
    }
    func choose(_ choice: AIConsentChoice) async throws -> AIConsentSnapshot {
        let response: APIv1.Success<AIConsentSnapshot> = try await call("api_v1_ai_consent", choice)
        return response.data
    }
}

@MainActor @Observable
final class AIConsentModel {
    private(set) var snapshot: AIConsentSnapshot?
    private(set) var busy = false
    private(set) var message: String?
    private(set) var pending: AIConsentChoice?
    private let service: (any AIConsentService)?

    init(service: (any AIConsentService)?) { self.service = service }

    func load() async {
        guard !busy, pending == nil else { return }
        guard let service else { message = "privacy.unconfigured"; return }
        busy = true
        defer { busy = false }
        do { snapshot = try await service.consent(); message = nil }
        catch { snapshot = nil; message = "privacy.loadError" }
    }

    func choose(_ granted: Bool) async {
        guard !busy, let service else { return }
        if granted && snapshot?.disclosure == nil { return }
        // Preserve operation UUID on ambiguous failure. No optimistic success.
        if pending == nil {
            pending = AIConsentChoice(operation_id: UUID(), granted: granted, disclosure: snapshot?.disclosure)
        }
        guard let choice = pending else { return }
        busy = true
        defer { busy = false }
        do {
            snapshot = try await service.choose(choice)
            pending = nil
            message = nil
        } catch let failure as APIv1.Failure where failure.code == "validation_failed" {
            // A changed disclosure needs a fresh review, not an endless retry of stale consent.
            pending = nil
            snapshot = nil
            message = "privacy.loadError"
        } catch { message = "privacy.saveError" }
    }
}
