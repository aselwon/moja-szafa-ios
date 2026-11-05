import SwiftUI

@MainActor
final class WardrobeReviewModel: ObservableObject {
    @Published private(set) var snapshot: StatisticsSnapshot?
    @Published private(set) var kept: Set<UUID> = []
    @Published private(set) var busy = false
    @Published private(set) var errorKey: String?
    @Published private(set) var journalFailed = false
    private let repository: any WardrobeRepository
    private let journalURL: URL

    init(repository: any WardrobeRepository, journalURL: URL) {
        self.repository = repository; self.journalURL = journalURL
        if FileManager.default.fileExists(atPath: journalURL.path) {
            do { kept = Set(try JSONDecoder().decode([UUID].self, from: Data(contentsOf: journalURL))) }
            catch { journalFailed = true; errorKey = "review.storage" }
        }
    }
    func load() async {
        guard !busy else { return }
        busy = true; errorKey = journalFailed ? "review.storage" : nil
        defer { busy = false }
        do { snapshot = try await repository.statisticsSnapshot() }
        catch { snapshot = nil; errorKey = "foundation.loadFailed" }
    }
    func candidates(now: Date = Date(), timezone: TimeZone = .current) -> [GarmentStatistics] {
        guard let snapshot else { return [] }
        let stats = WardrobeStatistics(snapshot: snapshot, period: .quarter, includeArchived: false, now: now, timezone: timezone)
        return stats.rows.filter { row in
            // Recent estimated history has no dates: do not label it rare just
            // because there are few individually recorded events.
            if let history = row.garment.initialWearHistory, history.count > 0, history.startDate > stats.cutoff90 { return false }
            return row.activityDays <= 2
        }.sorted { a,b in
            a.activityDays == b.activityDays ? a.id.uuidString < b.id.uuidString : a.activityDays < b.activityDays
        }
    }
    @discardableResult func keep(_ id: UUID, value: Bool = true) -> Bool {
        guard !busy, !journalFailed else { return false }
        var next = kept
        if value { next.insert(id) } else { next.remove(id) }
        do {
            try FileManager.default.createDirectory(at: journalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(next.sorted { $0.uuidString < $1.uuidString }).write(to: journalURL,
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            var url = journalURL; var values = URLResourceValues(); values.isExcludedFromBackup = true
            try url.setResourceValues(values)
            kept = next; errorKey = nil; return true
        } catch { errorKey = "review.storage"; return false }
    }
    func resetKept() {
        guard !busy else { return }
        do {
            try FileManager.default.createDirectory(at: journalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode([UUID]()).write(to: journalURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            var url = journalURL; var values = URLResourceValues(); values.isExcludedFromBackup = true
            try url.setResourceValues(values)
            kept = []; journalFailed = false; errorKey = nil
        } catch { errorKey = "review.storage" }
    }
    func archive(_ garment: Garment) async {
        guard !busy else { return }
        busy = true; errorKey = nil
        defer { busy = false }
        do {
            _ = try await repository.setArchived(id: garment.id, archived: true)
            snapshot = try await repository.statisticsSnapshot()
        } catch {
            // Never present an unverified result after a failed refresh.
            snapshot = nil; errorKey = "review.archiveFailed"
        }
    }
}

@MainActor
final class ReviewOutfitsModel: ObservableObject {
    @Published private(set) var items: [Outfit] = []
    @Published private(set) var loading = false
    @Published private(set) var errorKey: String?
    private let repository: any OutfitRepository
    init(repository: any OutfitRepository) { self.repository = repository }
    func load(garmentID: UUID) async {
        guard !loading else { return }
        loading = true; errorKey = nil; items = []
        defer { loading = false }
        do {
            var cursor: UUID?; var cursors = Set<UUID>(); var seen = Set<UUID>(); var matching: [Outfit] = []
            repeat {
                try Task.checkCancellation()
                let page = try await repository.outfits(cursor: cursor)
                for outfit in page.items where outfit.garments.contains(where: { $0.id == garmentID }) {
                    if seen.insert(outfit.id).inserted { matching.append(outfit) }
                }
                cursor = page.nextCursor
                if let cursor, !cursors.insert(cursor).inserted { throw APIClientError.invalidResponse }
            } while cursor != nil
            try Task.checkCancellation()
            items = matching
        } catch { if !(error is CancellationError) { errorKey = "foundation.loadFailed" } }
    }
}

struct WardrobeReviewView: View {
    @StateObject private var model: WardrobeReviewModel
    let wardrobe: any WardrobeRepository
    let outfits: any OutfitRepository
    @State private var showingKept = false
    @State private var reminding: Garment?
    @State private var confirmingReset = false
    init(wardrobe: any WardrobeRepository, outfits: any OutfitRepository, journalURL: URL) {
        self.wardrobe = wardrobe; self.outfits = outfits
        _model = StateObject(wrappedValue: WardrobeReviewModel(repository: wardrobe, journalURL: journalURL))
    }
    var body: some View {
        List {
            Section {
                Text("review.rule")
                Text("review.local").font(.caption)
                Toggle("review.showKept", isOn: $showingKept)
                if model.snapshot?.pendingChanges == true { Text("statistics.pending").font(.caption) }
                if model.journalFailed { Button("review.reset") { confirmingReset = true } }
            }
            if model.busy { ProgressView("common.loading") }
            if let key = model.errorKey {
                Text(LocalizedStringKey(key))
                Button("common.retry") { Task { await model.load() } }.disabled(model.busy)
            }
            if model.snapshot != nil {
                let rows = model.candidates().filter { showingKept || !model.kept.contains($0.id) }
                if rows.isEmpty { Text("review.empty") }
                ForEach(rows) { row in
                    Section {
                        Text(verbatim: row.garment.name).font(.headline)
                        LabeledContent("review.days", value: "\(row.activityDays)")
                        Button("review.remind") { reminding = row.garment }
                        if model.kept.contains(row.id) {
                            Button("review.undoKeep") { model.keep(row.id, value: false) }.disabled(model.journalFailed)
                        } else {
                            Button("review.keep") { model.keep(row.id) }.disabled(model.journalFailed)
                        }
                        Button("review.archive") { Task { await model.archive(row.garment) } }
                    }.disabled(model.busy)
                }
            }
        }
        .buttonStyle(.borderless)
        .navigationTitle("review.title")
        .confirmationDialog("review.reset", isPresented: $confirmingReset) {
            Button("review.reset", role: .destructive) { model.resetKept() }
        } message: { Text("review.resetExplanation") }
        .task { await model.load() }
        .refreshable { await model.load() }
        .sheet(item: $reminding) { garment in
            NavigationStack { ReviewOutfitsView(garment: garment, wardrobe: wardrobe, outfits: outfits) }
        }
    }
}

private struct ReviewOutfitsView: View {
    let garment: Garment
    let wardrobe: any WardrobeRepository
    @StateObject private var model: ReviewOutfitsModel
    @Environment(\.dismiss) private var dismiss
    init(garment: Garment, wardrobe: any WardrobeRepository, outfits: any OutfitRepository) {
        self.garment = garment; self.wardrobe = wardrobe
        _model = StateObject(wrappedValue: ReviewOutfitsModel(repository: outfits))
    }
    var body: some View {
        List {
            Text(verbatim: garment.name).font(.headline)
            Text("review.savedOnly").font(.caption)
            if model.loading { ProgressView("common.loading") }
            if let key = model.errorKey {
                Text(LocalizedStringKey(key))
                Button("common.retry") { Task { await model.load(garmentID: garment.id) } }
            }
            if !model.loading && model.errorKey == nil && model.items.isEmpty { Text("review.noOutfits") }
            ForEach(model.items) { outfit in
                Section {
                    Text(verbatim: outfit.name)
                    OutfitCollage(garments: outfit.garments, repository: wardrobe)
                }
            }
        }
        .navigationTitle("review.remind")
        .toolbar { Button("outfits.cancel") { dismiss() } }
        .task { await model.load(garmentID: garment.id) }
    }
}
