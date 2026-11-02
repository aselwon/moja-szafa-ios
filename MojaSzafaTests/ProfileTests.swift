import XCTest
@testable import MojaSzafa

@MainActor
final class ProfileTests: XCTestCase {
    private var directory: URL!
    private var store: ProfileStore!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store = ProfileStore(directory: directory)
    }

    override func tearDown() async throws {
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    func testEmptyPreferencesCanCompleteAndSurviveRelaunch() {
        let account = UUID()
        let model = ProfileModel(accountID: account, store: store)
        model.load()
        XCTAssertFalse(model.saved.onboardingCompleted)
        model.finish(ProfilePreferences())
        let reopened = ProfileModel(accountID: account, store: store)
        reopened.load()
        XCTAssertTrue(reopened.saved.onboardingCompleted)
        XCTAssertTrue(reopened.saved.styles.isEmpty)
        XCTAssertTrue(reopened.saved.colors.isEmpty)
        XCTAssertTrue(reopened.saved.priorities.isEmpty)
    }

    func testSkipDiscardsUnconfirmedSelections() {
        let model = ProfileModel(accountID: UUID(), store: store)
        model.load()
        var draft = ProfilePreferences()
        draft.styles = ["classic"]
        model.finish(draft, skipping: true)
        XCTAssertTrue(model.saved.onboardingCompleted)
        XCTAssertTrue(model.saved.styles.isEmpty)
    }

    func testEditsPersistAndAccountsRemainIsolated() throws {
        let account = UUID()
        let model = ProfileModel(accountID: account, store: store)
        model.load()
        var draft = ProfilePreferences()
        draft.styles = ["casual", "minimal"]
        draft.colors = ["neutral"]
        draft.priorities = ["comfort"]
        // Draft changes are not persisted until Save.
        XCTAssertEqual(try store.load(accountID: account), ProfilePreferences())
        model.finish(draft)
        XCTAssertEqual(try store.load(accountID: account), model.saved)
        XCTAssertEqual(try store.load(accountID: UUID()), ProfilePreferences())
        draft = model.saved
        draft.colors = []
        XCTAssertTrue(model.save(draft))
        XCTAssertTrue(try store.load(accountID: account).colors.isEmpty)
        XCTAssertTrue(model.saved.onboardingCompleted)
    }

    func testFailedSaveDoesNotAdvanceOnboardingAndCanRetry() throws {
        let model = ProfileModel(accountID: UUID(), store: store)
        model.load()
        // A regular file at the directory path simulates unavailable storage.
        try Data([0]).write(to: directory)
        model.finish(ProfilePreferences())
        XCTAssertFalse(model.saved.onboardingCompleted)
        XCTAssertEqual(model.message, "profile.saveError")
        try FileManager.default.removeItem(at: directory)
        model.finish(ProfilePreferences())
        XCTAssertTrue(model.saved.onboardingCompleted)
        XCTAssertNil(model.message)
    }

    func testCorruptProfileIsNotSilentlyOverwritten() throws {
        let account = UUID()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(account.uuidString).appendingPathExtension("json")
        let corrupt = Data("invalid".utf8)
        try corrupt.write(to: file)
        let model = ProfileModel(accountID: account, store: store)
        model.load()
        XCTAssertFalse(model.loaded)
        XCTAssertEqual(model.message, "profile.loadError")
        XCTAssertFalse(model.save(ProfilePreferences()))
        XCTAssertEqual(try Data(contentsOf: file), corrupt)
    }
}
