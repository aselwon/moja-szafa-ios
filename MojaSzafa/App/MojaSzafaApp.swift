import SwiftUI

@main
struct MojaSzafaApp: App {
    private let dependencies = AppDependencies.live()

    var body: some Scene {
        WindowGroup {
            AuthenticationGateView(dependencies: dependencies)
                .tint(Color("accent"))
        }
    }
}
