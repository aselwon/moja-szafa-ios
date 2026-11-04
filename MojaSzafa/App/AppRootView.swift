import SwiftUI

struct AppRootView: View {
    let dependencies: AppDependencies
    let accountID: UUID

    var body: some View {
        TabView {
            NavigationStack { TodayView(dependencies: dependencies).toolbar {
                NavigationLink("wear.history") { WearHistoryView(store: dependencies.wearStore ?? dependencies.offline) }
            } }
                .tabItem { Label("tab.today", systemImage: "sun.max") }
            NavigationStack { WardrobeView(repository: dependencies.wardrobe, accountID: accountID) }
                .tabItem { Label("tab.wardrobe", systemImage: "tshirt") }
            NavigationStack { OutfitsView(repository: dependencies.outfits, wardrobe: dependencies.wardrobe, wearStore: dependencies.wearStore ?? dependencies.offline) }
                .tabItem { Label("tab.outfits", systemImage: "square.stack") }
            NavigationStack { StatisticsView() }
                .tabItem { Label("tab.statistics", systemImage: "chart.bar") }
        }
    }
}
