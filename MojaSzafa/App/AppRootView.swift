import SwiftUI

struct AppRootView: View {
    let dependencies: AppDependencies
    let accountID: UUID
    @StateObject private var personalization: PersonalizationModel
    @StateObject private var planner: PlannerModel

    init(dependencies: AppDependencies, accountID: UUID) {
        self.dependencies = dependencies; self.accountID = accountID
        _planner = StateObject(wrappedValue: PlannerModel(repository: dependencies.planner, journalURL: dependencies.plannerJournalURL))
        _personalization = StateObject(wrappedValue: PersonalizationModel(repository: dependencies.outfits,
            journalURL: dependencies.personalizationIntentURL(accountID: accountID)))
    }

    private var plannerLink: some View {
        NavigationLink("planner.title") {
            PlannerView(model: planner, outfits: dependencies.outfits, wardrobe: dependencies.wardrobe)
        }
    }

    private var tripsLink: some View {
        NavigationLink("trips.title") {
            TripsView(repository: dependencies.trips, outfits: dependencies.outfits, wardrobe: dependencies.wardrobe, journalURL: dependencies.tripJournalURL)
        }
    }

    var body: some View {
        TabView {
            NavigationStack { TodayView(dependencies: dependencies, accountID: accountID, personalization: personalization).toolbar {
                plannerLink
                NavigationLink("wear.history") { WearHistoryView(store: dependencies.wearStore ?? dependencies.offline) }
            } }
                .tabItem { Label("tab.today", systemImage: "sun.max") }
            NavigationStack {
                WardrobeView(repository: dependencies.wardrobe, accountID: accountID)
                    .toolbar { NavigationLink("purchase.title") { PurchasePreviewView(dependencies: dependencies, accountID: accountID) } }
            }
                .tabItem { Label("tab.wardrobe", systemImage: "tshirt") }
            NavigationStack { OutfitsView(repository: dependencies.outfits, wardrobe: dependencies.wardrobe, wearStore: dependencies.wearStore ?? dependencies.offline, personalization: personalization).toolbar { plannerLink; tripsLink } }
                .tabItem { Label("tab.outfits", systemImage: "square.stack") }
            NavigationStack { StatisticsView(repository: dependencies.wardrobe).toolbar {
                NavigationLink("review.title") {
                    WardrobeReviewView(wardrobe: dependencies.wardrobe, outfits: dependencies.outfits,
                        journalURL: dependencies.reviewDecisionsURL(accountID: accountID))
                }
            } }
                .tabItem { Label("tab.statistics", systemImage: "chart.bar") }
        }
    }
}
