import Combine
import Foundation
import PhotosUI
import SwiftUI

struct PurchaseMetadata: Codable, Sendable, Equatable {
    var category: APIv1.Category = .top
    var colors: [String] = []
    var seasons: [String] = []
    var formality: Int? = nil
    enum CodingKeys: String, CodingKey { case category, colors, seasons, formality }
    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(category, forKey: .category); try c.encode(colors, forKey: .colors)
        try c.encode(seasons, forKey: .seasons); try c.encode(formality, forKey: .formality)
    }
}
struct PurchaseCandidate: Codable, Identifiable, Sendable {
    let id: UUID
    let name: String
    let metadata: PurchaseMetadata
    let price_grosz: Int64?
    let image_id: UUID?
    let expires_at: Double
    let status: String
    let garment_id: UUID?
}
struct PurchaseCreate: Codable, Sendable, Equatable {
    let action = "create"
    let operation_id: UUID
    let candidate_id: UUID
    let name: String
    let price_grosz: Int64?
    let metadata: PurchaseMetadata
    enum CodingKeys: String, CodingKey { case action, operation_id, candidate_id, name, price_grosz, metadata }
    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(action, forKey: .action); try c.encode(operation_id, forKey: .operation_id)
        try c.encode(candidate_id, forKey: .candidate_id); try c.encode(name, forKey: .name)
        try c.encode(price_grosz, forKey: .price_grosz); try c.encode(metadata, forKey: .metadata)
    }
}
struct PurchaseFit: Decodable, Sendable {
    struct Match: Decodable, Sendable {
        let garment_ids: [UUID]
        let rationale: String
        let complete: Bool
        let missing_categories: [String]
        let purchase_candidate_id: UUID
    }
    let outfits: [Match]
    let shortfall_reason: String?
}
struct PurchaseJob: Decodable, Sendable {
    let job_id: UUID
    let kind: APIv1.JobKind
    let status: APIv1.JobStatus
    let result: PurchaseFit?
    let error_code: String?
}
protocol PurchaseRepository: Sendable {
    func candidates() async throws -> [PurchaseCandidate]
    func createCandidate(_ request: PurchaseCreate) async throws -> PurchaseCandidate
    func candidate(_ id: UUID) async throws -> PurchaseCandidate
    func uploadCandidatePhoto(candidateID: UUID, imageID: UUID, data: Data) async throws
    func candidatePhoto(imageID: UUID) async throws -> Data
    func confirmCandidate(id: UUID, operationID: UUID) async throws -> PurchaseCandidate
    func discardCandidate(id: UUID, operationID: UUID) async throws
    func checkCandidate(id: UUID, operationID: UUID) async throws -> UUID
    func candidateResult(jobID: UUID) async throws -> PurchaseJob
}
extension APIClient: PurchaseRepository {
    func candidates() async throws -> [PurchaseCandidate] {
        let r: APIv1.Success<[PurchaseCandidate]> = try await call("api_v1_purchase", ["action": "list"]); return r.data
    }
    func createCandidate(_ request: PurchaseCreate) async throws -> PurchaseCandidate {
        let r: APIv1.Success<PurchaseCandidate> = try await call("api_v1_purchase", request); return r.data
    }
    func candidate(_ id: UUID) async throws -> PurchaseCandidate {
        let r: APIv1.Success<PurchaseCandidate> = try await call("api_v1_purchase", ["action":"get", "candidate_id":id.uuidString]); return r.data
    }
    func confirmCandidate(id: UUID, operationID: UUID) async throws -> PurchaseCandidate {
        struct Request: Encodable { let action = "confirm"; let candidate_id: UUID; let operation_id: UUID; let confirmed = true }
        let r: APIv1.Success<PurchaseCandidate> = try await call("api_v1_purchase", Request(candidate_id: id, operation_id: operationID)); return r.data
    }
    func discardCandidate(id: UUID, operationID: UUID) async throws {
        let _: APIv1.Success<PurchaseCandidate> = try await call("api_v1_purchase", ["action":"discard", "candidate_id":id.uuidString, "operation_id":operationID.uuidString])
    }
    func checkCandidate(id: UUID, operationID: UUID) async throws -> UUID {
        struct Admission: Decodable, Sendable { let job_id: UUID; let status: APIv1.JobStatus }
        let r: APIv1.Success<Admission> = try await call("api_v1_purchase_fit", ["candidate_id":id, "operation_id":operationID]); return r.data.job_id
    }
    func candidateResult(jobID: UUID) async throws -> PurchaseJob {
        let r: APIv1.Success<PurchaseJob> = try await call("api_v1_purchase_fit_result", ["job_id":jobID]); return r.data
    }
}

@MainActor
final class PurchasePreviewModel: ObservableObject {
    struct Intent: Codable { let operationID: UUID; var jobID: UUID? }
    struct Journal: Codable {
        var draft: PurchaseCreate?
        var imageID: UUID?
        var confirmations: [String: UUID] = [:]
        var discards: [String: UUID] = [:]
        var checks: [String: Intent] = [:]
    }
    struct Match: Identifiable {
        let id = UUID()
        let garments: [Garment]
        let rationale: String
        let complete: Bool
    }
    @Published private(set) var items: [PurchaseCandidate] = []
    @Published private(set) var matches: [UUID: [Match]] = [:]
    @Published private(set) var busy = false
    @Published private(set) var message: String?
    @Published private(set) var journal = Journal()
    private var readable = true
    let repository: (any PurchaseRepository)?
    let wardrobe: any WardrobeRepository
    let directory: URL
    private var journalURL: URL { directory.appendingPathComponent("intents.json") }
    init(repository: (any PurchaseRepository)?, wardrobe: any WardrobeRepository, directory: URL) {
        self.repository = repository; self.wardrobe = wardrobe; self.directory = directory
        if FileManager.default.fileExists(atPath: journalURL.path) {
            do { journal = try JSONDecoder().decode(Journal.self, from: Data(contentsOf: journalURL)) }
            catch { readable = false; message = "purchase.storage" }
        }
    }
    private func persist(_ next: Journal) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(next).write(to: journalURL, options: [.atomic, .completeFileProtection])
        journal = next
    }
    func load() async {
        guard !busy else { return }
        guard let repository else { message = "foundation.serviceUnavailable"; return }
        busy = true; defer { busy = false }
        do { let list = try await repository.candidates(); try Task.checkCancellation(); items = list }
        catch { fail(error) }
    }
    func create(name: String, price: Int64?, metadata: PurchaseMetadata, photo: Data?) async {
        guard readable, !busy else { return }
        guard let repository else { message = "foundation.serviceUnavailable"; return }
        busy = true; message = nil; defer { busy = false }
        do {
            if journal.draft == nil {
                guard let photo, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 200, price.map({ $0 >= 0 }) ?? true else { throw APIClientError.invalidRequest }
                let id = UUID(); let normalized = try await PhotoProcessor().normalize(photo)
                try Task.checkCancellation()
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try normalized.write(to: directory.appendingPathComponent(id.uuidString + ".jpg"), options: [.atomic, .completeFileProtection])
                var next = journal
                next.draft = PurchaseCreate(operation_id: UUID(), candidate_id: id, name: name, price_grosz: price, metadata: metadata)
                next.imageID = UUID(); try persist(next)
            }
            guard let draft = journal.draft, let imageID = journal.imageID else { throw APIClientError.invalidRequest }
            _ = try await repository.createCandidate(draft)
            let photoURL = directory.appendingPathComponent(draft.candidate_id.uuidString + ".jpg")
            try await repository.uploadCandidatePhoto(candidateID: draft.candidate_id, imageID: imageID, data: Data(contentsOf: photoURL))
            let candidate = try await repository.candidate(draft.candidate_id)
            try Task.checkCancellation()
            guard candidate.image_id == imageID else { throw APIClientError.invalidResponse }
            var next = journal; next.draft = nil; next.imageID = nil; try persist(next)
            try? FileManager.default.removeItem(at: photoURL)
            items.removeAll { $0.id == candidate.id }; items.insert(candidate, at: 0)
        } catch { fail(error) }
    }
    func discardDraft() async {
        guard readable, !busy, let repository, let draft = journal.draft else { return }
        busy = true; defer { busy = false }
        do {
            var next = journal
            let operation = next.discards[draft.candidate_id.uuidString] ?? UUID()
            next.discards[draft.candidate_id.uuidString] = operation; try persist(next)
            do { try await repository.discardCandidate(id: draft.candidate_id, operationID: operation) }
            catch let failure as APIv1.Failure where failure.code == "not_found" { }
            try Task.checkCancellation()
            next.draft = nil; next.imageID = nil; try persist(next)
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(draft.candidate_id.uuidString + ".jpg"))
            items.removeAll { $0.id == draft.candidate_id }; message = nil
        } catch { fail(error) }
    }
    func confirm(_ id: UUID) async {
        guard readable, !busy, let repository else { return }
        busy = true; message = nil; defer { busy = false }
        do {
            var next = journal
            let operation = next.confirmations[id.uuidString] ?? UUID()
            next.confirmations[id.uuidString] = operation; try persist(next)
            let purchased = try await repository.confirmCandidate(id: id, operationID: operation)
            try Task.checkCancellation()
            guard purchased.id == id, purchased.status == "purchased", purchased.garment_id != nil else { throw APIClientError.invalidResponse }
            items.removeAll { $0.id == id }; matches[id] = nil; message = "purchase.purchased"
        } catch { fail(error) }
    }
    func discard(_ id: UUID) async {
        guard readable, !busy, let repository else { return }
        busy = true; defer { busy = false }
        do {
            var next = journal; let operation = next.discards[id.uuidString] ?? UUID()
            next.discards[id.uuidString] = operation; try persist(next)
            try await repository.discardCandidate(id: id, operationID: operation)
            try Task.checkCancellation(); items.removeAll { $0.id == id }; matches[id] = nil
        } catch { fail(error) }
    }
    func check(_ id: UUID, maxPolls: Int = 60) async {
        guard readable, !busy, let repository else { return }
        busy = true; message = nil; defer { busy = false }
        do {
            var next = journal
            var intent = next.checks[id.uuidString] ?? Intent(operationID: UUID())
            next.checks[id.uuidString] = intent; try persist(next)
            if intent.jobID == nil {
                intent.jobID = try await repository.checkCandidate(id: id, operationID: intent.operationID)
                next.checks[id.uuidString] = intent; try persist(next)
            }
            guard let jobID = intent.jobID else { throw APIClientError.invalidResponse }
            for index in 0..<max(1, maxPolls) {
                let job = try await repository.candidateResult(jobID: jobID)
                try Task.checkCancellation()
                guard job.job_id == jobID, job.kind == .purchaseFit, (job.status == .succeeded) == (job.result != nil) else { throw APIClientError.invalidResponse }
                if let result = job.result {
                    let candidate = try await repository.candidate(id)
                    let current = try await wardrobe.garments()
                    try Task.checkCancellation()
                    guard candidate.status == "considering", candidate.expires_at > Date().timeIntervalSince1970, result.outfits.count <= 3 else { throw APIClientError.invalidResponse }
                    var resolved: [Match] = []
                    for proposal in result.outfits {
                        guard proposal.purchase_candidate_id == id, !proposal.garment_ids.isEmpty, Set(proposal.garment_ids).count == proposal.garment_ids.count else { throw APIClientError.invalidResponse }
                        let garments = proposal.garment_ids.compactMap { owned in current.first { $0.id == owned && !$0.archived && $0.availability == .available } }
                        guard garments.count == proposal.garment_ids.count else {
                            next.checks[id.uuidString] = nil; try persist(next); message = "purchase.stale"; return
                        }
                        resolved.append(Match(garments: garments, rationale: proposal.rationale, complete: proposal.complete))
                    }
                    matches[id] = resolved; message = resolved.isEmpty ? "purchase.noMatches" : nil
                    return
                }
                if [.failed, .cancelled, .deadLetter].contains(job.status) {
                    next.checks[id.uuidString] = nil; try persist(next); message = "purchase.aiFailed"; return
                }
                message = "purchase.pending"
                if index + 1 < maxPolls { try await Task.sleep(for: .seconds(2)) }
            }
        } catch { fail(error) }
    }
    private func fail(_ error: any Error) {
        if error is CancellationError { return }
        if let failure = error as? APIv1.Failure {
            message = ["consent_required":"purchase.consent", "quota_exceeded":"purchase.quota", "ai_disabled":"purchase.aiUnavailable", "not_found":"purchase.expired", "unauthorized":"purchase.account", "account_unavailable":"purchase.account"][failure.code] ?? "purchase.failed"
        } else { message = error is URLError ? "outfits.offline" : "purchase.failed" }
    }
}

struct PurchasePreviewView: View {
    @StateObject private var model: PurchasePreviewModel
    @State private var selection: PhotosPickerItem?
    @State private var photo: Data?
    @State private var name = ""
    @State private var price = ""
    @State private var metadata = PurchaseMetadata()
    @State private var confirming: PurchaseCandidate?
    @State private var task: Task<Void, Never>?
    @State private var photoFailed = false
    let consent: (any AIConsentService)?
    let accountID: UUID
    init(dependencies: AppDependencies, accountID: UUID) {
        self.accountID = accountID
        consent = dependencies.aiConsent
        _model = StateObject(wrappedValue: PurchasePreviewModel(repository: dependencies.purchases,
            wardrobe: dependencies.wardrobe, directory: dependencies.purchaseDirectory(accountID: accountID)))
    }
    private var priceGrosz: Int64? {
        guard !price.isEmpty else { return nil }
        let parts = price.replacingOccurrences(of: ",", with: ".").split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count <= 2, parts[0].count <= 12, let units = Int64(parts[0]), units >= 0 else { return nil }
        if parts.count == 1 { return units * 100 }
        guard (1...2).contains(parts[1].count), let fraction = Int64(parts[1]), fraction >= 0 else { return nil }
        return units * 100 + fraction * (parts[1].count == 1 ? 10 : 1)
    }
    var body: some View {
        List {
            Section {
                Text("purchase.temporary")
                Text("purchase.metadataOnly")
                Text("purchase.noForecast")
                NavigationLink("privacy.title") { AIPrivacyView(service: consent) }
            }
            Section {
                if model.journal.draft != nil {
                    Text("purchase.savedDraft")
                    Button("purchase.discard", role: .destructive) { task = Task { await model.discardDraft() } }
                }
                Group {
                PhotosPicker(selection: $selection, matching: .images) { Label("purchase.photo", systemImage: "photo") }
                if let photo, let image = UIImage(data: photo) { Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 160) }
                if photoFailed { Text("purchase.photoFailed") }
                TextField("garment.name", text: $name)
                Picker("garment.category", selection: $metadata.category) {
                    ForEach(APIv1.Category.allCases, id: \.self) { Text(LocalizedStringKey("garment.category.\($0.rawValue)")).tag($0) }
                }
                TextField("purchase.price", text: $price).keyboardType(.decimalPad)
                Picker("purchase.formality", selection: $metadata.formality) {
                    Text("purchase.unknown").tag(Int?.none)
                    ForEach(1...5, id: \.self) { Text("\($0)").tag(Optional($0)) }
                }
                // Explicit optional metadata only; no photo-recognition claim.
                ForEach(["spring", "summer", "autumn", "winter"], id: \.self) { season in
                    Toggle(LocalizedStringKey("garment.season.\(season)"), isOn: Binding(
                        get: { metadata.seasons.contains(season) }, set: { on in metadata.seasons.removeAll { $0 == season }; if on { metadata.seasons.append(season) } }))
                }
                }.disabled(model.journal.draft != nil)
                Button(model.journal.draft == nil ? "purchase.create" : "common.retry") {
                    task = Task { await model.create(name: name, price: priceGrosz, metadata: metadata, photo: photo) }
                }.disabled(model.busy || (model.journal.draft == nil && (photo == nil || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (!price.isEmpty && priceGrosz == nil))))
            } header: { Text("purchase.new") }
            .disabled(model.busy)
            if let message = model.message { Text(LocalizedStringKey(message)) }
            if model.busy { ProgressView("common.loading") }
            ForEach(model.items) { candidate in
                Section {
                    Text(verbatim: candidate.name).font(.headline)
                    if let imageID = candidate.image_id { PurchaseThumbnail(repository: model.repository, imageID: imageID) }
                    Text(Date(timeIntervalSince1970: candidate.expires_at), style: .date)
                    Button("purchase.check") { task = Task { await model.check(candidate.id) } }
                        .disabled(model.busy || candidate.image_id == nil)
                    ForEach(model.matches[candidate.id] ?? []) { match in
                        OutfitCollage(garments: match.garments, repository: model.wardrobe)
                        Text(verbatim: match.rationale)
                        if !match.complete { Text("suggestions.incomplete") }
                    }
                    Text("purchase.manualFallback")
                    NavigationLink("tab.wardrobe") { WardrobeView(repository: model.wardrobe, accountID: accountID) }
                    Button("purchase.confirm") { confirming = candidate }.disabled(model.busy || candidate.image_id == nil)
                    Button("purchase.discard", role: .destructive) { task = Task { await model.discard(candidate.id) } }.disabled(model.busy)
                }
            }
        }
        .navigationTitle("purchase.title")
        .task { await model.load() }
        .refreshable { await model.load() }
        .onDisappear { task?.cancel() }
        .task(id: selection) {
            guard let selection else { return }
            do {
                guard let bytes = try await selection.loadTransferable(type: Data.self) else { throw PhotoImportError.invalidImage }
                let normalized = try await PhotoProcessor().normalize(bytes)
                try Task.checkCancellation(); photo = normalized; photoFailed = false
            } catch { if !(error is CancellationError) { photoFailed = true } }
        }
        .confirmationDialog("purchase.confirmQuestion", isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } })) {
            Button("purchase.confirm") { if let id = confirming?.id { task = Task { await model.confirm(id) } }; confirming = nil }
            Button("outfits.cancel", role: .cancel) { confirming = nil }
        } message: { Text("purchase.confirmDetail") }
    }
}
private struct PurchaseThumbnail: View {
    let repository: (any PurchaseRepository)?
    let imageID: UUID
    @State private var data: Data?
    var body: some View {
        Group {
            if let data, let image = UIImage(data: data) { Image(uiImage: image).resizable().scaledToFit() }
            else { Image(systemName: "photo").accessibilityLabel(Text("purchase.photo")) }
        }.frame(maxHeight: 160).task(id: imageID) { data = try? await repository?.candidatePhoto(imageID: imageID) }
    }
}
