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
