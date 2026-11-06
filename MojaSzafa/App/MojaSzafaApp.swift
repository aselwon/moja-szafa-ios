import SwiftUI
#if DEBUG
import UIKit
#endif

@main
struct MojaSzafaApp: App {
    private let dependencies = AppDependencies.live()
    @StateObject private var reminders = ReminderModel.live()
    @StateObject private var widget = WardrobeWidgetModel.live()

    init() {
        #if DEBUG
        // Opt-in UI acceptance runs reset only this local welcome flag. They do
        // not create sessions, send email, or change the backend composition.
        if ProcessInfo.processInfo.arguments.contains("--ui-test-reset-welcome") {
            UserDefaults.standard.removeObject(forKey: "welcome.seen.v1")
        }
        if DemoMode.isEnabled(arguments: ProcessInfo.processInfo.arguments) { return }
        #endif
        DataExportClient.clearPreviousDownloads()
    }

    var body: some Scene {
        WindowGroup {
            Group {
                #if WARDROBE_BENCHMARK && targetEnvironment(simulator)
                if ProcessInfo.processInfo.arguments.contains("--wardrobe-benchmark") {
                    WardrobeBenchmarkRoot()
                } else {
                    AuthenticationGateView(dependencies: dependencies)
                }
                #else
                #if DEBUG
                if DemoMode.isEnabled(arguments: ProcessInfo.processInfo.arguments) {
                    DemoRootView()
                } else {
                    AuthenticationGateView(dependencies: dependencies)
                }
                #else
                AuthenticationGateView(dependencies: dependencies)
                #endif
                #endif
            }.tint(Color("accent")).environmentObject(reminders).environmentObject(widget)
        }
    }
}

// Explicitly opt-in, simulator-only build instrumentation. Ordinary Debug,
// Staging and Release builds do not contain this route or its synthetic data.
#if WARDROBE_BENCHMARK && targetEnvironment(simulator)
private struct WardrobeBenchmarkRoot: View {
    private static let account = UUID(uuidString: "59000000-0000-4000-8000-000000000001")!
    private let repository: OfflineStore?
    @State private var validated = false
    @State private var invalidFixture = false

    init() {
        do {
            let database = OfflineDatabase(url: URL.applicationSupportDirectory
                .appendingPathComponent("LaunchBenchmark/fixture.sqlite"))
            if ProcessInfo.processInfo.arguments.contains("--seed-wardrobe-benchmark") {
                let garments = (0..<1000).map { index in
                    SyncGarment(id: UUID(uuidString: String(format: "59000001-0000-4000-8000-%012x", index))!,
                        version: 1, deleted: false,
                        fields: APIv1.GarmentFields(name: String(format: "Benchmark garment %04d", index),
                            category: .top, priceGrosz: 10000 + Int64(index), availability: .available))
                }
                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = TimeZone(secondsFromGMT: 0)!
                let start = calendar.date(from: DateComponents(year: 2021, month: 1, day: 1))!
                let formatter = DateFormatter()
                formatter.calendar = calendar; formatter.timeZone = calendar.timeZone
                formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
                let wears = (0..<1826).map { index in
                    SyncWear(id: UUID(uuidString: String(format: "59000002-0000-4000-8000-%012x", index))!,
                        version: 1, deleted: false,
                        wornOn: formatter.string(from: calendar.date(byAdding: .day, value: index, to: start)!),
                        timezone: "UTC", garmentIDs: (0..<5).map { garments[(index * 5 + $0) % 1000].id })
                }
                var state = OfflineStore.State(accountID: Self.account)
                state.garments = garments; state.wears = wears
                try database.write(JSONEncoder().encode(state))
            }
            // Missing or damaged fixtures fail visibly instead of measuring an
            // empty wardrobe. Measured launches never regenerate the fixture.
            guard FileManager.default.fileExists(atPath: database.url.path) else { throw OfflineError.invalidState }
            repository = try OfflineStore(accountID: Self.account, database: database, remote: BenchmarkOfflineRemote())
        } catch { repository = nil }
    }

    var body: some View {
        if let repository, validated {
            NavigationStack {
                WardrobeView(repository: repository, accountID: Self.account, allowsPhotoImport: false)
            }
        } else if repository == nil || invalidFixture {
            Text("Benchmark fixture unavailable").accessibilityIdentifier("benchmark.fixture.failed")
        } else {
            ProgressView().task {
                guard let repository else { return }
                let state = await repository.status()
                validated = state.garments.count == 1000 && state.wears.count == 1826
                    && state.wears.reduce(0, { $0 + $1.garmentIDs.count }) == 9130 && state.outbox.isEmpty
                invalidFixture = !validated
            }
        }
    }
}

private struct BenchmarkOfflineRemote: OfflineRemote {
    func snapshot() async throws -> SyncSnapshot { throw URLError(.notConnectedToInternet) }
    func save(_ operation: APIv1.SaveGarment) async throws -> APIv1.GarmentDTO { throw URLError(.notConnectedToInternet) }
    func save(_ operation: SaveWear) async throws -> SyncWear { throw URLError(.notConnectedToInternet) }
}
#endif

// The preview is compiled out of Release and never supplies authentication,
// server success, account data or a network transport to the production app.
#if DEBUG
enum DemoMode {
    static let accountID = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
    static func isEnabled(arguments: [String]) -> Bool { arguments.contains("--demo") }
}

@MainActor
private struct DemoRootView: View {
    @State private var repository = DemoWardrobe.make()

    var body: some View {
        VStack(spacing: 0) {
            demoBanner
            TabView {
                NavigationStack {
                    WardrobeView(repository: repository, accountID: DemoMode.accountID, allowsPhotoImport: false)
                }.tabItem { Label("tab.wardrobe", systemImage: "tshirt") }
                NavigationStack {
                    OutfitsView(repository: repository, wardrobe: repository)
                }.tabItem { Label("tab.outfits", systemImage: "square.stack") }
                NavigationStack {
                    List {
                        Section("demo.tryTitle") {
                            Text("demo.tryBrowse")
                            Text("demo.tryDetails")
                            Text("demo.tryOutfits")
                        }
                        Section("demo.localTitle") {
                            Text("demo.dataNotice")
                            Text("demo.disclosure")
                        }
                    }.navigationTitle("demo.about")
                }.tabItem { Label("demo.about", systemImage: "info.circle") }
            }
        }
    }

    // A short visible label preserves space at AX5; full disclosure remains
    // available to VoiceOver and in the About tab, without reducing text size.
    private var demoBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles.rectangle.stack").accessibilityHidden(true)
            Text("demo.banner").font(.caption.bold())
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .foregroundStyle(Color("primaryText"))
        .background(Color("accent").opacity(0.13))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("demo.disclosure"))
        .fixedSize(horizontal: false, vertical: true)
    }
}

actor DemoWardrobe: WardrobeRepository, OutfitRepository {
    private var items: [Garment]
    private let photos: [UUID: Data]
    private var savedOutfits: [Outfit]
    private var operations: [UUID: (SaveOutfit, Outfit)] = [:]

    private init(items: [Garment], photos: [UUID: Data]) {
        self.items = items
        self.photos = photos
        savedOutfits = [
            Outfit(version: 1, name: "Na spokojny dzień", favorite: true, garments: Array(items.prefix(3))),
            Outfit(version: 1, name: "Spacer po mieście", garments: [items[0], items[3], items[5]])
        ]
    }

    @MainActor static func make() -> DemoWardrobe {
        let samples: [(String, APIv1.Category, String, UIColor, Int64)] = [
            ("Granatowy T-shirt", .top, "tshirt.fill", .systemIndigo, 6900),
            ("Jasne spodnie", .bottom, "pants", .systemBrown, 14900),
            ("Białe sneakersy", .shoes, "shoe.fill", .darkGray, 22900),
            ("Lekka kurtka", .outerwear, "tshirt.fill", .systemOrange, 18900),
            ("Zielona sukienka", .dress, "dress", .systemTeal, 17900),
            ("Torba na co dzień", .accessory, "bag.fill", .systemBrown, 9900)
        ]
        var items: [Garment] = []
        var photos: [UUID: Data] = [:]
        for (index, sample) in samples.enumerated() {
            let id = UUID(uuidString: String(format: "00000000-0000-4000-8001-%012d", index + 1))!
            items.append(Garment(id: id, name: sample.0, category: sample.1, priceGrosz: sample.4, imageID: id))
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = true
            let image = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 400), format: format).image { context in
                UIColor(red: 0.96, green: 0.95, blue: 0.92, alpha: 1).setFill()
                context.fill(CGRect(x: 0, y: 0, width: 400, height: 400))
                if sample.2 == "pants" || sample.2 == "dress" {
                    let path = UIBezierPath()
                    let points: [CGPoint] = sample.2 == "pants"
                        ? [CGPoint(x: 140, y: 65), CGPoint(x: 260, y: 65), CGPoint(x: 280, y: 330), CGPoint(x: 220, y: 330), CGPoint(x: 200, y: 170), CGPoint(x: 180, y: 330), CGPoint(x: 120, y: 330)]
                        : [CGPoint(x: 165, y: 65), CGPoint(x: 235, y: 65), CGPoint(x: 235, y: 150), CGPoint(x: 295, y: 330), CGPoint(x: 105, y: 330), CGPoint(x: 165, y: 150)]
                    path.move(to: points[0]); points.dropFirst().forEach { path.addLine(to: $0) }; path.close()
                    sample.3.setFill(); path.fill()
                } else {
                    UIImage(systemName: sample.2, withConfiguration: UIImage.SymbolConfiguration(pointSize: 200, weight: .regular))?
                        .withTintColor(sample.3, renderingMode: .alwaysOriginal)
                        .draw(in: CGRect(x: 80, y: 95, width: 240, height: 210))
                }
            }
            photos[id] = image.pngData()
        }
        return DemoWardrobe(items: items, photos: photos)
    }

    func garments() async throws -> [Garment] { items }
    func detail(id: UUID) async throws -> GarmentDetail {
        guard let garment = items.first(where: { $0.id == id }) else { throw APIClientError.invalidRequest }
        return GarmentDetail(garment: garment, wornOn: [])
    }
    func setStatus(id: UUID, availability: APIv1.Availability, archived: Bool) async throws -> GarmentDetail {
        guard let index = items.firstIndex(where: { $0.id == id }) else { throw APIClientError.invalidRequest }
        items[index].availability = availability
        items[index].archived = archived
        return try await detail(id: id)
    }
    func thumbnail(imageID: UUID) async throws -> Data {
        guard let data = photos[imageID] else { throw APIClientError.invalidRequest }
        return data
    }
    func original(imageID: UUID) async throws -> Data { try await thumbnail(imageID: imageID) }
    func outfits(cursor: UUID?) async throws -> OutfitPage { OutfitPage(items: cursor == nil ? savedOutfits : [], nextCursor: nil) }
    func saveOutfit(_ request: SaveOutfit) async throws -> Outfit {
        if let previous = operations[request.operationID] {
            guard previous.0 == request else { throw APIClientError.invalidRequest }
            return previous.1
        }
        guard (savedOutfits.first(where: { $0.id == request.id })?.version ?? 0) == request.baseVersion else {
            throw APIv1.Failure(code: "version_conflict", message: "Demo outfit changed", requestID: UUID())
        }
        let garments = request.garmentIDs.compactMap { id in items.first { $0.id == id } }
        let result = Outfit(id: request.id, version: request.baseVersion + 1, name: request.name,
                            favorite: request.favorite, garments: garments)
        guard result.isValid, garments.count == request.garmentIDs.count else { throw APIClientError.invalidRequest }
        savedOutfits.removeAll { $0.id == result.id }; savedOutfits.insert(result, at: 0)
        operations[request.operationID] = (request, result)
        return result
    }
}
#endif
