import SwiftUI

struct AppRootView: View {
    let dependencies: AppDependencies
    let accountID: UUID
    @StateObject private var personalization: PersonalizationModel
    @StateObject private var planner: PlannerModel
    @ObservedObject var reminders: ReminderModel
    @ObservedObject var widget: WardrobeWidgetModel
    @State private var selectedTab = 1

    init(dependencies: AppDependencies, accountID: UUID, reminders: ReminderModel, widget: WardrobeWidgetModel) {
        self.widget = widget
        self.reminders = reminders
        self.dependencies = dependencies; self.accountID = accountID
        _planner = StateObject(wrappedValue: PlannerModel(repository: dependencies.planner, journalURL: dependencies.plannerJournalURL,
            mutationStarted: { reminders.planMutationStarted(); widget.planMutationStarted() },
            mutationFinished: { reminders.planMutationFinished(); widget.planMutationFinished() }))
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
        TabView(selection: $selectedTab) {
            NavigationStack { TodayView(dependencies: dependencies, accountID: accountID, personalization: personalization).toolbar {
                plannerLink
                NavigationLink("wear.history") { WearHistoryView(store: dependencies.wearStore ?? dependencies.offline) }
            }.navigationDestination(isPresented: $widget.showWearConfirmation) {
                WidgetWearConfirmationView(planner: planner, personalization: personalization, dependencies: dependencies)
            } }
                .tabItem { Label("tab.today", systemImage: "sun.max") }.tag(0)
            NavigationStack {
                WardrobeView(repository: dependencies.wardrobe, accountID: accountID, recognition: dependencies.photoRecognition, consent: dependencies.aiConsent)
                    .toolbar { NavigationLink("purchase.title") { PurchasePreviewView(dependencies: dependencies, accountID: accountID) } }
            }
                .tabItem { Label("tab.wardrobe", systemImage: "tshirt") }.tag(1)
            NavigationStack { OutfitsView(repository: dependencies.outfits, wardrobe: dependencies.wardrobe, wearStore: dependencies.wearStore ?? dependencies.offline, personalization: personalization).toolbar { plannerLink; tripsLink } }
                .tabItem { Label("tab.outfits", systemImage: "square.stack") }.tag(2)
            NavigationStack { StatisticsView(repository: dependencies.wardrobe).toolbar {
                NavigationLink("review.title") {
                    WardrobeReviewView(wardrobe: dependencies.wardrobe, outfits: dependencies.outfits,
                        journalURL: dependencies.reviewDecisionsURL(accountID: accountID))
                }
            } }
                .tabItem { Label("tab.statistics", systemImage: "chart.bar") }.tag(3)
        }
        .onChange(of: widget.showWearConfirmation, initial: true) { _, show in
            if show { selectedTab = 0; reminders.route = nil }
        }
        .onAppear { widget.consumeIntent() }
        .sheet(item: $reminders.route) { route in
            NavigationStack {
                if route.kind == .plan {
                    PlannerView(model: planner, outfits: dependencies.outfits, wardrobe: dependencies.wardrobe,
                                initialDay: ReminderSchedule.parseDay(route.day, timezone: .current))
                } else {
                    // Existing outfit wear action always asks for explicit confirmation.
                    OutfitsView(repository: dependencies.outfits, wardrobe: dependencies.wardrobe,
                                wearStore: dependencies.wearStore ?? dependencies.offline, personalization: personalization)
                }
            }
        }
    }
}
