import SwiftUI

struct AppRootView: View {
    let dependencies: AppDependencies
    let accountID: UUID
    @StateObject private var personalization: PersonalizationModel

    init(dependencies: AppDependencies, accountID: UUID) {
        self.dependencies = dependencies; self.accountID = accountID
        _personalization = StateObject(wrappedValue: PersonalizationModel(repository: dependencies.outfits,
            journalURL: dependencies.personalizationIntentURL(accountID: accountID)))
    }

    var body: some View {
        TabView {
            NavigationStack { TodayView(dependencies: dependencies, accountID: accountID, personalization: personalization).toolbar {
                NavigationLink("wear.history") { WearHistoryView(store: dependencies.wearStore ?? dependencies.offline) }
            } }
                .tabItem { Label("tab.today", systemImage: "sun.max") }
            NavigationStack {
                WardrobeView(repository: dependencies.wardrobe, accountID: accountID)
                    .toolbar { NavigationLink("purchase.title") { PurchasePreviewView(dependencies: dependencies, accountID: accountID) } }
            }
                .tabItem { Label("tab.wardrobe", systemImage: "tshirt") }
            NavigationStack { OutfitsView(repository: dependencies.outfits, wardrobe: dependencies.wardrobe, wearStore: dependencies.wearStore ?? dependencies.offline, personalization: personalization) }
                .tabItem { Label("tab.outfits", systemImage: "square.stack") }
            NavigationStack { StatisticsView() }
                .tabItem { Label("tab.statistics", systemImage: "chart.bar") }
        }
    }
}
