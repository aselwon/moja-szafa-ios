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
                #if DEBUG
                if DemoMode.isEnabled(arguments: ProcessInfo.processInfo.arguments) {
                    DemoRootView()
                } else {
                    AuthenticationGateView(dependencies: dependencies)
                }
                #else
                AuthenticationGateView(dependencies: dependencies)
                #endif
            }.tint(Color("accent")).environmentObject(reminders).environmentObject(widget)
        }
    }
}

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
                        Section("Co możesz sprawdzić") {
                            Text("Przeglądaj ubrania, szukaj i filtruj kolekcję.")
                            Text("Otwórz szczegóły ubrania i zmień jego dostępność.")
                            Text("Edytuj przykładowe zestawy lub utwórz własny.")
                        }
                        Section("To jest lokalny podgląd") {
                            Text("Ubrania i ilustracje są przykładowe. Zmiany w kolekcji i zestawach pozostają tylko w pamięci aplikacji.")
                            Text("Ten tryb nie loguje do konta, nie łączy się z serwerem i nie uruchamia AI. Nie potwierdza gotowości tych usług.")
                        }
                    }.navigationTitle("O podglądzie")
                }.tabItem { Label("O podglądzie", systemImage: "info.circle") }
            }
        }
    }

    // Reserve real layout space so large text cannot cover navigation or filters.
    private var demoBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles.rectangle.stack")
            VStack(alignment: .leading, spacing: 2) {
                Text("PODGLĄD DEMO").font(.caption.bold())
                Text("Dane przykładowe · bez połączenia z serwerem").font(.caption2)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .foregroundStyle(Color("primaryText"))
        .background(Color("accent").opacity(0.13))
        .accessibilityElement(children: .combine)
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
