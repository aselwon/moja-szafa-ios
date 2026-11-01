import SwiftUI

struct AppRootView: View {
    let dependencies: AppDependencies

    var body: some View {
        TabView {
            NavigationStack { TodayView() }
                .tabItem { Label("tab.today", systemImage: "sun.max") }
            NavigationStack { WardrobeView(repository: dependencies.wardrobe) }
                .tabItem { Label("tab.wardrobe", systemImage: "tshirt") }
            NavigationStack { OutfitsView() }
                .tabItem { Label("tab.outfits", systemImage: "square.stack") }
            NavigationStack { StatisticsView() }
                .tabItem { Label("tab.statistics", systemImage: "chart.bar") }
        }
    }
}
