import XCTest
@testable import MojaSzafa

@MainActor
final class OutfitsTests: XCTestCase {
    func testValidationAndMembershipAreIndependentFromWearSnapshot() {
        let garment = Garment(id: UUID(), name: "Shirt", archived: true)
        var outfit = Outfit(name: "Work", garments: [garment])
        let wear = SyncWear(id: UUID(), version: 1, deleted: false, wornOn: "2026-01-01", timezone: "Europe/Warsaw", garmentIDs: outfit.garments.map(\.id))
        XCTAssertTrue(outfit.isValid)
        XCTAssertTrue(outfit.garments[0].archived)
        outfit.garments = [Garment(id: UUID(), name: "Dress")]
        XCTAssertEqual(wear.garmentIDs, [garment.id])
        outfit.name = " \n "
        XCTAssertFalse(outfit.isValid)
        outfit.name = "Work"
        outfit.garments = []
        XCTAssertFalse(outfit.isValid)
        outfit.garments = [garment, garment]
        XCTAssertFalse(outfit.isValid)
    }

    func testConflictKeepsExistingListAndAllowsReload() async {
        let outfit = Outfit(version: 3, name: "Server", garments: [Garment(id: UUID(), name: "Dress")])
        let model = OutfitsModel(repository: ConflictingOutfitFixture(outfit: outfit))
        await model.load()
        var edited = outfit
        edited.name = "Local"
        let saved = await model.save(edited)
        XCTAssertFalse(saved)
        XCTAssertNil(model.pending)
        XCTAssertEqual(model.errorKey, "outfits.conflict")
        XCTAssertEqual(model.items, [outfit])
        await model.load()
        XCTAssertNil(model.errorKey)
        XCTAssertEqual(model.items, [outfit])
    }

    func testTimeoutRetryUsesSameIntentThenUpdatesExistingOutfit() async {
        let repository = OutfitFixture()
        let model = OutfitsModel(repository: repository)
        var outfit = Outfit(name: "Work", garments: [Garment(id: UUID(), name: "Shirt")])
        let first = await model.save(outfit)
        XCTAssertFalse(first)
        XCTAssertNotNil(model.pending)
        let second = await model.save(outfit)
        XCTAssertTrue(second)
        XCTAssertNil(model.pending)
        let requests = await repository.requests
        XCTAssertEqual(requests[0], requests[1])
        XCTAssertEqual(model.items.count, 1)
        outfit = model.items[0]
        outfit.name = "Weekend"; outfit.favorite = true
        let edited = await model.save(outfit)
        XCTAssertTrue(edited)
        XCTAssertEqual(model.items.count, 1)
        XCTAssertEqual(model.items[0].name, "Weekend")
        XCTAssertTrue(model.items[0].favorite)
        let updatedRequests = await repository.requests
        XCTAssertNotEqual(updatedRequests[1].operationID, updatedRequests[2].operationID)
        XCTAssertEqual(updatedRequests[2].baseVersion, 1)
    }
}

private actor OutfitFixture: OutfitRepository {
    var requests: [SaveOutfit] = []
    func outfits(cursor: UUID?) async throws -> OutfitPage { OutfitPage(items: [], nextCursor: nil) }
    func saveOutfit(_ request: SaveOutfit) async throws -> Outfit {
        requests.append(request)
        if requests.count == 1 { throw URLError(.timedOut) }
        return Outfit(id: request.id, version: request.baseVersion + 1, name: request.name,
                      favorite: request.favorite, garments: request.garmentIDs.map { Garment(id: $0, name: "Shirt") })
    }
}

private struct ConflictingOutfitFixture: OutfitRepository {
    let outfit: Outfit
    func outfits(cursor: UUID?) async throws -> OutfitPage { OutfitPage(items: [outfit], nextCursor: nil) }
    func saveOutfit(_ request: SaveOutfit) async throws -> Outfit {
        throw APIv1.Failure(code: "version_conflict", message: "Changed", requestID: UUID())
    }
}

@MainActor
final class SuggestionsTests: XCTestCase {
    func testManualReplacementPreservesOtherSlotsAndWorksAfterAIFailure() async {
        let top = Garment(id: UUID(), name: "Top", category: .top)
        let bottom = Garment(id: UUID(), name: "Bottom", category: .bottom)
        let shoes = Garment(id: UUID(), name: "Shoes", category: .shoes)
        let replacement = Garment(id: UUID(), name: "Other top", category: .top)
        let source = SuggestionFixture(ids: [top.id, bottom.id, shoes.id])
        let model = SuggestionsModel(source: source, wardrobe: SuggestionWardrobe(items: [top, bottom, shoes, replacement]),
                                     outfits: OutfitFixture(), offline: nil)
        await model.load()
        XCTAssertTrue(model.items[0].missing.isEmpty)
        let id = model.items[0].id
        await source.fail()
        await model.load()
        XCTAssertNotNil(model.errorKey)
        XCTAssertEqual(model.items.count, 1)
        await model.replace(suggestionID: id, garmentID: top.id, with: replacement)
        XCTAssertNil(model.errorKey)
        XCTAssertEqual(model.items[0].outfit.garments.map(\.id), [replacement.id, bottom.id, shoes.id])
        XCTAssertTrue(model.items[0].edited)
        XCTAssertFalse(model.items[0].worn)
        await model.replace(suggestionID: id, garmentID: replacement.id, with: shoes)
        XCTAssertNotNil(model.errorKey)
        XCTAssertEqual(model.items[0].outfit.garments.map(\.id), [replacement.id, bottom.id, shoes.id])
    }

    func testUnknownAndUnavailableIDsFailClosed() async {
        let garment = Garment(id: UUID(), name: "Laundry", availability: .laundry)
        for ids in [[UUID()], [garment.id], [garment.id, garment.id]] {
            let model = SuggestionsModel(source: SuggestionFixture(ids: ids), wardrobe: SuggestionWardrobe(items: [garment]),
                                         outfits: OutfitFixture(), offline: nil)
            await model.load()
            XCTAssertTrue(model.items.isEmpty)
            XCTAssertNotNil(model.errorKey)
        }
    }

    func testPendingSaveLocksReplacementAndRetriesSamePayload() async {
        let top = Garment(id: UUID(), name: "Top", category: .top)
        let replacement = Garment(id: UUID(), name: "Dress", category: .dress)
        let outfits = OutfitFixture()
        let model = SuggestionsModel(source: SuggestionFixture(ids: [top.id]),
                                     wardrobe: SuggestionWardrobe(items: [top, replacement]), outfits: outfits, offline: nil)
        await model.load()
        XCTAssertEqual(model.items[0].missing, [.bottom, .shoes])
        let id = model.items[0].id
        await model.save(id)
        XCTAssertNotNil(model.saves.pending)
        await model.replace(suggestionID: id, garmentID: top.id, with: replacement)
        XCTAssertEqual(model.items[0].outfit.garments, [top])
        await model.save(id)
        let requests = await outfits.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0], requests[1])
        XCTAssertNil(model.saves.pending)
        XCTAssertFalse(model.items[0].worn)
    }
}

private actor SuggestionFixture: SuggestionRepository {
    let ids: [UUID]
    var failing = false
    init(ids: [UUID]) { self.ids = ids }
    func fail() { failing = true }
    func latestSuggestions() async throws -> SuggestionResult? {
        if failing { throw URLError(.notConnectedToInternet) }
        return SuggestionResult(outfits: [.init(garment_ids: ids, rationale: "For work")], shortfall_reason: nil)
    }
}
private struct SuggestionWardrobe: WardrobeRepository {
    let items: [Garment]
    func garments() async throws -> [Garment] { items }
}

extension SuggestionsTests {
    func testWearIsExplicitLocalDaySnapshotAndSurvivesRestart() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = OfflineDatabase(url: directory.appendingPathComponent("state.sqlite"))
        let account = UUID()
        let store = try OfflineStore(accountID: account, database: database, remote: SuggestionsOfflineRemote())
        let id = try await store.saveGarment(fields: .init(name: "Dress", category: .dress, priceGrosz: nil, availability: .available))
        let model = SuggestionsModel(source: SuggestionFixture(ids: [id]), wardrobe: store, outfits: OutfitFixture(), offline: store)
        await model.load()
        let before = await store.status()
        XCTAssertTrue(before.wears.isEmpty)
        let suggestionID = try XCTUnwrap(model.items.first?.id)
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-01-01T23:30:00Z"))
        let zone = try XCTUnwrap(TimeZone(identifier: "Europe/Warsaw"))
        await model.wear(suggestionID, now: date, timezone: zone)
        await model.wear(suggestionID, now: date, timezone: zone)
        XCTAssertNil(model.errorKey)
        let restored = try OfflineStore(accountID: account, database: database, remote: SuggestionsOfflineRemote())
        let state = await restored.status()
        XCTAssertEqual(state.wears.count, 1)
        XCTAssertEqual(state.wears.first?.garmentIDs, [id])
        XCTAssertEqual(state.wears.first?.wornOn, "2026-01-02")
        XCTAssertEqual(state.wears.first?.timezone, "Europe/Warsaw")
    }
}

private struct SuggestionsOfflineRemote: OfflineRemote {
    func snapshot() async throws -> SyncSnapshot { throw URLError(.notConnectedToInternet) }
    func save(_ operation: APIv1.SaveGarment) async throws -> APIv1.GarmentDTO { throw URLError(.notConnectedToInternet) }
    func save(_ operation: SaveWear) async throws -> SyncWear { throw URLError(.notConnectedToInternet) }
}

@MainActor
final class GenerationTests: XCTestCase {
    private func make(_ source: GenerationFixture, url: URL? = nil) -> SuggestionsModel {
        SuggestionsModel(source: source, wardrobe: SuggestionWardrobe(items: []),
            outfits: OutfitFixture(), offline: nil, intentURL: url, pollDelay: {})
    }
    func testAmbiguousAdmissionReplaysDurableIntentAfterRecreation() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("intent.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let source = GenerationFixture(failAdmissionOnce: true)
        let first = make(source, url: url)
        let originalWeather = GenerationWeatherContext(temperature_celsius: -5.5, source: "manual", valid_until: nil)
        await first.generate(count: 3, weather: originalWeather, maxPolls: 1)
        XCTAssertEqual(first.generationError, "outfits.offline")
        let operation = try XCTUnwrap(first.pendingGeneration?.request.operation_id)
        let restored = make(source, url: url)
        await restored.generate(count: 9,
            weather: GenerationWeatherContext(temperature_celsius: 25, source: "manual", valid_until: nil), maxPolls: 1)
        let requests = await source.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0], requests[1])
        XCTAssertEqual(requests[1].operation_id, operation)
        XCTAssertEqual(requests[1].count, 3)
        XCTAssertEqual(requests[1].weather, originalWeather)
        XCTAssertNil(restored.pendingGeneration)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
    func testBoundedPollingResumesJobWithoutReadmission() async {
        let source = GenerationFixture(status: .running)
        let model = make(source)
        await model.generate(count: 2, maxPolls: 2)
        XCTAssertEqual(model.generationError, "generation.waiting")
        XCTAssertEqual(model.generationStatus, .running)
        await model.generate(count: 7, maxPolls: 1)
        let requests = await source.requests
        let polls = await source.polls
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(polls, 3)
    }
    func testConsentAndQuotaNeverBecomeFalseSuccess() async {
        for (code, key) in [("consent_required", "generation.consent"), ("quota_exceeded", "generation.quota"), ("ai_disabled", "generation.disabled")] {
            let source = GenerationFixture(admissionError: code)
            let model = make(source)
            await model.generate(count: 2, maxPolls: 1)
            XCTAssertEqual(model.generationError, key)
            XCTAssertNotNil(model.pendingGeneration)
            XCTAssertTrue(model.items.isEmpty)
            let polls = await source.polls
            XCTAssertEqual(polls, 0)
        }
    }
    func testForeignResultRejectedAndPendingIntentRetained() async {
        let model = make(GenerationFixture(wrongJob: true))
        await model.generate(count: 2, maxPolls: 1)
        XCTAssertEqual(model.generationError, "generation.failed")
        XCTAssertNotNil(model.pendingGeneration)
        XCTAssertTrue(model.items.isEmpty)
    }
    func testUnreadableIntentFailsClosedAndAccountFilesRemainSeparate() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let a = root.appendingPathComponent("account-a.json")
        try Data("invalid".utf8).write(to: a)
        let source = GenerationFixture()
        let broken = make(source, url: a)
        await broken.generate(count: 2, maxPolls: 1)
        XCTAssertEqual(broken.generationError, "generation.storage")
        let requests = await source.requests
        XCTAssertEqual(requests.count, 0)
        let other = make(source, url: root.appendingPathComponent("account-b.json"))
        XCTAssertNil(other.pendingGeneration)
        XCTAssertNil(other.generationError)
    }
    func testAccountViewCancellationStopsPollingButKeepsIntent() async throws {
        let source = GenerationFixture(status: .running)
        let model = SuggestionsModel(source: source, wardrobe: SuggestionWardrobe(items: []),
            outfits: OutfitFixture(), offline: nil, pollDelay: { try await Task.sleep(for: .seconds(60)) })
        let task = Task { await model.generate(count: 2) }
        while await source.polls == 0 { await Task.yield() }
        task.cancel()
        await task.value
        XCTAssertFalse(model.generating)
        XCTAssertNotNil(model.pendingGeneration)
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertNil(model.generationError)
        let polls = await source.polls
        XCTAssertEqual(polls, 1)
    }
    func testRequestWireDefaultsAndValidation() throws {
        let request = GenerationRequest(operation_id: UUID(), count: 3)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        XCTAssertTrue(object["pinned_garment_id"] is NSNull)
        XCTAssertTrue((object["occasion"] as? [String: Any])?["formality"] is NSNull)
        XCTAssertEqual((object["preferences"] as? [String: [String]])?["colors"], [])
        XCTAssertThrowsError(try GenerationRequest(operation_id: UUID(), count: 11).validate())
    }
}

private actor GenerationFixture: SuggestionRepository {
    var requests: [GenerationRequest] = []
    var polls = 0
    let jobID = UUID()
    var failAdmissionOnce: Bool
    let status: APIv1.JobStatus
    let admissionError: String?
    let wrongJob: Bool
    let resultIDs: [UUID]
    init(failAdmissionOnce: Bool = false, status: APIv1.JobStatus = .succeeded,
         admissionError: String? = nil, wrongJob: Bool = false, resultIDs: [UUID] = []) {
        self.failAdmissionOnce = failAdmissionOnce; self.status = status
        self.admissionError = admissionError; self.wrongJob = wrongJob; self.resultIDs = resultIDs
    }
    func latestSuggestions() async throws -> SuggestionResult? { nil }
    func generate(_ request: GenerationRequest) async throws -> GenerationAdmission {
        requests.append(request)
        if failAdmissionOnce { failAdmissionOnce = false; throw URLError(.timedOut) }
        if let admissionError { throw APIv1.Failure(code: admissionError, message: "", requestID: UUID()) }
        return GenerationAdmission(job_id: jobID, status: .queued)
    }
    func generationResult(jobID: UUID) async throws -> GenerationJob {
        polls += 1
        return GenerationJob(job_id: wrongJob ? UUID() : self.jobID, kind: .outfitGeneration, status: status,
            result: status == .succeeded ? SuggestionResult(outfits: resultIDs.isEmpty ? [] : [.init(garment_ids: resultIDs, rationale: "For today")], shortfall_reason: nil) : nil,
            error_code: nil)
    }
}

extension GenerationTests {
    func testLiveClientUsesFrozenAuthenticatedRPCs() async throws {
        let transport = GenerationTransport()
        let client = try APIClient(baseURL: URL(string: "https://gateway.example")!, transport: transport) { "signed-session" }
        let request = GenerationRequest(operation_id: UUID(), count: 3)
        let admitted = try await client.generate(request)
        _ = try await client.generationResult(jobID: admitted.job_id)
        let sent = await transport.requests
        XCTAssertEqual(sent.map { $0.url!.lastPathComponent }, ["api_v1_generate_outfits", "api_v1_job_result"])
        XCTAssertTrue(sent.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer signed-session" })
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: sent[0].httpBody!) as? [String: Any])
        XCTAssertEqual((body["request"] as? [String: Any])?["operation_id"] as? String, request.operation_id.uuidString)
    }
}
private actor GenerationTransport: APITransport {
    var requests: [URLRequest] = []
    let job = UUID()
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        var value: [String: Any] = ["job_id": job.uuidString, "status": "queued"]
        if request.url!.lastPathComponent == "api_v1_job_result" {
            value["kind"] = "outfit_generation"; value["result"] = NSNull(); value["error_code"] = NSNull()
        }
        let body = try JSONSerialization.data(withJSONObject: ["data": value, "request_id": UUID().uuidString])
        return (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}


extension GenerationTests {
    func testCompletedStaleResultAllowsFreshExplicitIntent() async throws {
        let source = GenerationFixture(resultIDs: [UUID()])
        let model = SuggestionsModel(source: source, wardrobe: SuggestionWardrobe(items: []),
            outfits: OutfitFixture(), offline: nil)
        await model.generate(count: 3, maxPolls: 1)
        XCTAssertEqual(model.generationError, "generation.stale")
        XCTAssertNil(model.pendingGeneration)
        await model.generate(count: 3, maxPolls: 1)
        let requests = await source.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertNotEqual(requests[0].operation_id, requests[1].operation_id)
    }
    func testCompletedResultWardrobeNetworkFailureKeepsExistingJob() async {
        let source = GenerationFixture(resultIDs: [UUID()])
        let model = SuggestionsModel(source: source, wardrobe: OfflineGenerationWardrobe(),
            outfits: OutfitFixture(), offline: nil)
        await model.generate(count: 3, maxPolls: 1)
        let job = model.pendingGeneration?.jobID
        XCTAssertNotNil(job)
        XCTAssertEqual(model.generationError, "outfits.offline")
        await model.generate(count: 3, maxPolls: 1)
        XCTAssertEqual(model.pendingGeneration?.jobID, job)
        let requests = await source.requests
        XCTAssertEqual(requests.count, 1)
    }
}
private struct OfflineGenerationWardrobe: WardrobeRepository {
    func garments() async throws -> [Garment] { throw URLError(.notConnectedToInternet) }
}

@MainActor
final class PersonalizationTests: XCTestCase {
    func testUncertainFeedbackSurvivesRelaunchAndReplaysExactIntent() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("intent.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let fixture = PersonalizationFixture()
        let first = PersonalizationModel(repository: fixture, journalURL: url)
        let outfitID = UUID()
        await first.load(outfitID: outfitID)
        let saved = await first.save(action: .feedback, rating: "dislike", reason: "Too formal")
        XCTAssertFalse(saved)
        let intent = try XCTUnwrap(first.pending)
        let relaunched = PersonalizationModel(repository: fixture, journalURL: url)
        XCTAssertEqual(relaunched.pending, intent)
        await relaunched.load(outfitID: outfitID)
        let retried = await relaunched.retry()
        XCTAssertTrue(retried)
        XCTAssertNil(relaunched.pending)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        let requests = await fixture.mutations
        XCTAssertEqual(requests, [intent, intent])
        XCTAssertEqual(relaunched.state?.version, 7, "Must read current revision instead of trusting a cached acknowledgement")
    }
    func testResetFencesStaleMutationWithoutAutomaticRebase() async throws {
        let fixture = PersonalizationFixture(conflict: true)
        let model = PersonalizationModel(repository: fixture)
        await model.load()
        let saved = await model.save(action: .preferences, excluded: ["top"], colors: ["blue"])
        XCTAssertFalse(saved)
        XCTAssertNil(model.pending)
        XCTAssertNil(model.state)
        XCTAssertEqual(model.errorKey, "personalization.conflict")
        let second = await model.save(action: .reset)
        XCTAssertFalse(second, "A fresh explicit read is required")
        let requests = await fixture.mutations
        XCTAssertEqual(requests.count, 1)
    }
    func testCorruptJournalFailsClosed() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("invalid".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let fixture = PersonalizationFixture()
        let model = PersonalizationModel(repository: fixture, journalURL: url)
        await model.load()
        XCTAssertNil(model.state)
        XCTAssertEqual(model.errorKey, "personalization.storage")
        let saved = await model.save(action: .reset)
        XCTAssertFalse(saved)
        let requests = await fixture.mutations
        XCTAssertTrue(requests.isEmpty)
    }
}
private actor PersonalizationFixture: OutfitRepository {
    var mutations: [PersonalizationRequest] = []
    let conflict: Bool
    init(conflict: Bool = false) { self.conflict = conflict }
    func outfits(cursor: UUID?) async throws -> OutfitPage { OutfitPage(items: [], nextCursor: nil) }
    func saveOutfit(_ request: SaveOutfit) async throws -> Outfit { throw RepositoryError.backendNotConfigured }
    func personalization(_ request: PersonalizationRequest) async throws -> PersonalizationState {
        if request.action == .get { return PersonalizationState(version: 7, excludedCategories: [], colors: [], feedback: nil) }
        mutations.append(request)
        if conflict { throw APIv1.Failure(code: "version_conflict", message: "", requestID: UUID()) }
        if mutations.count == 1 { throw URLError(.timedOut) }
        return PersonalizationState(version: 2, excludedCategories: ["top"], colors: [], feedback: nil)
    }
}
