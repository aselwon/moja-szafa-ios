import SwiftUI

struct AppRootView: View {
    let dependencies: AppDependencies
    let accountID: UUID
    @StateObject private var planner: PlannerModel

    init(dependencies: AppDependencies, accountID: UUID) {
        self.dependencies = dependencies; self.accountID = accountID
        _planner = StateObject(wrappedValue: PlannerModel(repository: dependencies.planner, journalURL: dependencies.plannerJournalURL))
    }

    private var plannerLink: some View {
        NavigationLink("planner.title") {
            PlannerView(model: planner, outfits: dependencies.outfits, wardrobe: dependencies.wardrobe)
        }
    }

    var body: some View {
        TabView {
            NavigationStack { TodayView().toolbar { plannerLink } }
                .tabItem { Label("tab.today", systemImage: "sun.max") }
            NavigationStack { WardrobeView(repository: dependencies.wardrobe, accountID: accountID) }
                .tabItem { Label("tab.wardrobe", systemImage: "tshirt") }
            NavigationStack { OutfitsView(repository: dependencies.outfits, wardrobe: dependencies.wardrobe).toolbar { plannerLink } }
                .tabItem { Label("tab.outfits", systemImage: "square.stack") }
            NavigationStack { StatisticsView() }
                .tabItem { Label("tab.statistics", systemImage: "chart.bar") }
        }
    }
}
