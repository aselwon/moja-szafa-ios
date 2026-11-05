import SwiftUI

struct StatisticsView: View {
    @StateObject private var model: StatisticsModel
    @State private var period: WardrobeStatistics.Period = .all
    @State private var includeArchived = false
    init(repository: any WardrobeRepository) { _model = StateObject(wrappedValue: StatisticsModel(repository: repository)) }

    var body: some View {
        List {
            if model.loading { ProgressView("common.loading") }
            if let key = model.errorKey {
                Text(LocalizedStringKey(key))
                Button("common.retry") { Task { await model.load() } }
            }
            if let snapshot = model.snapshot {
                let stats = WardrobeStatistics(snapshot: snapshot, period: period, includeArchived: includeArchived)
                Section {
                    Picker("statistics.period", selection: $period) {
                        ForEach(WardrobeStatistics.Period.allCases, id: \.self) { value in
                            Text(LocalizedStringKey("statistics.period." + value.rawValue)).tag(value)
                        }
                    }
                    Toggle("statistics.archived", isOn: $includeArchived)
                    Text("statistics.scope").font(.caption)
                    if snapshot.cached { Text("statistics.cached").font(.caption) }
                    if snapshot.pendingChanges { Text("statistics.pending").font(.caption) }
                }
                Section("statistics.value") {
                    Text((stats.knownValueGrosz / 100).formatted(.currency(code: "PLN")))
                    LabeledContent("statistics.missingPrices", value: "\(stats.missingPrices)")
                    LabeledContent("statistics.items", value: "\(stats.rows.count)")
                }
                Section("statistics.mostWorn") {
                    if stats.mostWorn.isEmpty { Text("statistics.empty") }
                    ForEach(stats.mostWorn) { row in
                        LabeledContent { Text("\(row.activityDays)") } label: { Text(verbatim: row.garment.name) }
                    }
                }
                Section("statistics.cpw") {
                    Text("statistics.cpwScope").font(.caption)
                    if stats.costRanking.isEmpty { Text("statistics.empty") }
                    ForEach(stats.costRanking) { row in
                        VStack(alignment: .leading) {
                            Text(verbatim: row.garment.name)
                            if let price = row.cost.roundedGrosz { Text((Decimal(price) / 100).formatted(.currency(code: "PLN"))) }
                            if row.cost.isEstimated { Text("statistics.estimated").font(.caption) }
                        }
                    }
                }
                Section("statistics.never") {
                    if stats.neverWorn.isEmpty { Text("statistics.empty") }
                    ForEach(stats.neverWorn) { row in Text(verbatim: row.garment.name) }
                }
                Section("statistics.unused90") {
                    Text("statistics.unknownLastWear").font(.caption)
                    if stats.unused90.isEmpty { Text("statistics.empty") }
                    ForEach(stats.unused90) { row in Text(verbatim: row.garment.name) }
                }
            }
        }
        .navigationTitle("tab.statistics")
        .task { await model.load() }
        .refreshable { await model.load() }
    }
}
