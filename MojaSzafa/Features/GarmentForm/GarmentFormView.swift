import SwiftUI

struct GarmentFormView: View {
    @State private var form: GarmentForm
    @State private var price: String
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    let accept: (GarmentForm) -> Bool

    init(form: GarmentForm, accept: @escaping (GarmentForm) -> Bool) {
        _form = State(initialValue: form)
        _price = State(initialValue: form.priceText)
        self.accept = accept
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("garment.explanation")
                    TextField("garment.name", text: $form.name)
                    Picker("garment.category", selection: $form.category) {
                        ForEach(APIv1.Category.allCases, id: \.self) { category in
                            Text(LocalizedStringKey("garment.category.\(category.rawValue)")).tag(category)
                        }
                    }
                    TextField("garment.pattern", text: $form.pattern)
                    Picker("garment.formality", selection: $form.formality) {
                        Text("garment.unknown").tag(nil as Int?)
                        ForEach(1...5, id: \.self) { level in
                            Text(LocalizedStringKey("garment.formality.\(level)")).tag(Optional(level))
                        }
                    }
                }
                Section("garment.colors") {
                    ForEach(GarmentForm.palette, id: \.self) { color in
                        Toggle(LocalizedStringKey("garment.color.\(color)"), isOn: membership(color, in: $form.colors))
                    }
                }
                Section("garment.seasons") {
                    ForEach(GarmentForm.seasons, id: \.self) { season in
                        Toggle(LocalizedStringKey("garment.season.\(season)"), isOn: membership(season, in: $form.seasons))
                    }
                }
                Section("garment.purchase") {
                    TextField("garment.brand", text: $form.brand)
                    TextField("garment.price", text: $price).keyboardType(.decimalPad)
                    Text("garment.priceHint")
                    Toggle("garment.hasDate", isOn: Binding(get: { form.purchasedOn != nil }, set: { enabled in
                        form.purchasedOn = enabled ? GarmentForm.dateFormatter().string(from: Date()) : nil
                    }))
                    if form.purchasedOn != nil {
                        DatePicker("garment.date", selection: Binding(get: {
                            form.purchasedOn.flatMap { GarmentForm.dateFormatter().date(from: $0) } ?? Date()
                        }, set: { form.purchasedOn = GarmentForm.dateFormatter().string(from: $0) }), displayedComponents: .date)
                        .environment(\.timeZone, TimeZone(secondsFromGMT: 0)!)
                    }
                }
                Section {
                    if let error { Text(LocalizedStringKey(error)).foregroundStyle(.red) }
                    Button("garment.saveDraft") { save() }.buttonStyle(.borderedProminent)
                }
            }
            .navigationTitle("garment.title")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("common.cancel") { dismiss() } }
            }
            .interactiveDismissDisabled()
        }
    }

    private func membership(_ value: String, in values: Binding<[String]>) -> Binding<Bool> {
        Binding(get: { values.wrappedValue.contains(value) }, set: { enabled in
            values.wrappedValue.removeAll { $0 == value }
            if enabled { values.wrappedValue.append(value) }
        })
    }

    private func save() {
        do {
            form.priceGrosz = try GarmentForm.parsePrice(price)
            let validated = try form.validated()
            if accept(validated) { dismiss() } else { error = "import.storageFailed" }
        } catch let validation as GarmentForm.Validation {
            error = validation.rawValue
        } catch { self.error = "garment.invalidMetadata" }
    }
}
