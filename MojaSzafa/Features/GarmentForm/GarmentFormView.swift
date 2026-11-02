import SwiftUI

struct GarmentFormView: View {
    @StateObject private var model: GarmentFormModel
    @Environment(\.dismiss) private var dismiss
    let onSaved: () -> Void
    private let palette = ["black", "white", "gray", "beige", "brown", "red", "orange", "yellow", "green", "blue", "purple", "pink"]

    init(id: UUID, repository: any WardrobeRepository, suggestions: GarmentSuggestions? = nil,
         onSaved: @escaping () -> Void) {
        _model = StateObject(wrappedValue: GarmentFormModel(id: id, repository: repository, suggestions: suggestions))
        self.onSaved = onSaved
    }

    var body: some View {
        Form {
            Section {
                if model.hasSuggestions { Text("garment.aiReview") }
                TextField("garment.name", text: $model.values.name)
                Picker("garment.category", selection: $model.values.category) {
                    ForEach(APIv1.Category.allCases, id: \.self) { category in
                        Text(LocalizedStringKey("garment.category.\(category.rawValue)")).tag(category)
                    }
                }
                TextField("garment.pattern", text: $model.values.pattern)
            }
            Section("garment.colors") {
                // Text labels and native toggles remain usable without color vision.
                ForEach(Array(Set(palette + model.values.colors)).sorted(), id: \.self) { color in
                    Toggle(isOn: membership(color, in: $model.values.colors)) {
                        if palette.contains(color) { Text(LocalizedStringKey("garment.color.\(color)")) }
                        else { Text(verbatim: color) }
                    }
                }
            }
            Section("garment.seasons") {
                ForEach(["spring", "summer", "autumn", "winter"], id: \.self) { season in
                    Toggle(LocalizedStringKey("garment.season.\(season)"), isOn: membership(season, in: $model.values.seasons))
                }
                Picker("garment.formality", selection: $model.values.formality) {
                    ForEach(0...5, id: \.self) { level in
                        Text(LocalizedStringKey("garment.formality.\(level)")).tag(level)
                    }
                }
            }
            Section("garment.purchase") {
                TextField("garment.brand", text: $model.values.brand)
                TextField("garment.price", text: $model.values.price).keyboardType(.decimalPad)
                Text("garment.priceHelp").font(.footnote)
                Toggle("garment.hasDate", isOn: Binding(get: { model.values.purchasedOn != nil }, set: { enabled in
                    model.values.purchasedOn = enabled ? GarmentFormValues.dayFormatter().string(from: Date()) : nil
                }))
                if model.values.purchasedOn != nil {
                    DatePicker("garment.date", selection: Binding(get: {
                        GarmentFormValues.dayFormatter().date(from: model.values.purchasedOn ?? "") ?? Date()
                    }, set: { model.values.purchasedOn = GarmentFormValues.dayFormatter().string(from: $0) }), displayedComponents: .date)
                    .environment(\.timeZone, TimeZone(secondsFromGMT: 0)!)
                    .environment(\.calendar, Calendar(identifier: .gregorian))
                }
            }
            Section {
                Text("garment.offlineHelp").font(.footnote)
                if let error = model.errorKey { Text(LocalizedStringKey(error)).foregroundStyle(Color("danger")) }
                if model.saving { ProgressView("common.loading") }
                Button("garment.save") {
                    Task { if await model.save() { onSaved(); dismiss() } }
                }
            }
        }
        .disabled(model.saving)
        .navigationTitle("garment.title")
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("common.cancel") { dismiss() }.disabled(model.saving) } }
        .interactiveDismissDisabled(model.saving)
    }

    private func membership(_ value: String, in list: Binding<[String]>) -> Binding<Bool> {
        Binding(get: { list.wrappedValue.contains(value) }, set: { selected in
            list.wrappedValue.removeAll { $0 == value }
            if selected { list.wrappedValue.append(value) }
        })
    }
}
