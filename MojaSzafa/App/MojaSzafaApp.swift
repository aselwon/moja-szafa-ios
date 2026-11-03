import SwiftUI

@main
struct MojaSzafaApp: App {
    private let dependencies = AppDependencies.live()

    init() { DataExportClient.clearPreviousDownloads() }

    var body: some Scene {
        WindowGroup {
            AuthenticationGateView(dependencies: dependencies)
                .tint(Color("accent"))
        }
    }
}
