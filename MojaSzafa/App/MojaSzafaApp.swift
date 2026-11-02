import SwiftUI

@main
struct MojaSzafaApp: App {
    private let dependencies = AppDependencies.live()

    init() { ExportLocalFiles.clear() }

    var body: some Scene {
        WindowGroup {
            AuthenticationGateView(dependencies: dependencies)
                .tint(Color("accent"))
        }
    }
}
