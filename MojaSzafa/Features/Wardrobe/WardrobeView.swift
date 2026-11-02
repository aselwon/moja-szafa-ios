import SwiftUI

struct WardrobeView: View {
    @StateObject private var model: WardrobeModel
    @StateObject private var imports: PhotoImportModel
    @State private var reloadID = 0
    private let repository: any WardrobeRepository

    init(repository: any WardrobeRepository, accountID: UUID) {
        self.repository = repository
        _imports = StateObject(wrappedValue: PhotoImportModel(directory: URL.applicationSupportDirectory
            .appendingPathComponent("PhotoDrafts").appendingPathComponent(accountID.uuidString)))
        _model = StateObject(wrappedValue: WardrobeModel(repository: repository))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                NavigationLink("import.title") { PhotoImportView(model: imports, repository: repository) }
                switch model.state {
                case .idle, .loading:
                    ProgressView("common.loading")
                case .empty:
                    Text("foundation.wardrobeEmpty")
                case .loaded(let garments):
                    ForEach(garments) { garment in
                        Text(verbatim: garment.name)
                            .font(.headline)
                    }
                case .backendNotConfigured:
                    Text("foundation.serviceUnavailable")
                case .offline:
                    Text("foundation.offline")
                    retryButton
                case .failed:
                    Text("foundation.loadFailed")
                    retryButton
                }
            }
            .font(.body)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
        .foregroundStyle(Color("primaryText"))
        .background(Color("background"))
        .navigationTitle("tab.wardrobe")
        .task(id: reloadID) { await model.load() }
    }

    private var retryButton: some View {
        Button("common.retry") { reloadID += 1 }
            .buttonStyle(.bordered)
            .frame(minWidth: 44, minHeight: 44)
    }
}
