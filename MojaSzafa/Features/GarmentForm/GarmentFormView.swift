import SwiftUI

struct GarmentFormView: View {
    @State private var form: GarmentFormState
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    private let save: (GarmentDetails) -> Bool

    init(details: GarmentDetails, suggestions: GarmentSuggestions? = nil,
         save: @escaping (GarmentDetails) -> Bool) {
        _form = State(initialValue: GarmentFormState(details: details, suggestions: suggestions))
        self.save = save
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("garment.localDraft")
                    if form.hasSuggestions { Text("garment.aiCorrection") }
                    TextField("garment.name", text: $form.details.name)
                    Picker("garment.category", selection: $form.details.category) {
                        ForEach(APIv1.Category.allCases, id: \.self) { category in
                            Text(LocalizedStringKey("garment.category.\(category.rawValue)")).tag(category)
                        }
                    }
                    TextField("garment.pattern", text: $form.details.pattern)
                }
                Section("garment.colors") {
                    ForEach(GarmentDetails.palette, id: \.self) { color in
                        Toggle(LocalizedStringKey("garment.color.\(color)"), isOn: membership(color, in: $form.details.colors))
                    }
                }
                Section("garment.seasons") {
                    ForEach(GarmentDetails.seasonOptions, id: \.self) { season in
                        Toggle(LocalizedStringKey("garment.season.\(season)"), isOn: membership(season, in: $form.details.seasons))
                    }
                    Picker("garment.formality", selection: $form.details.formality) {
                        Text("garment.unknown").tag(Int?.none)
                        ForEach(1...5, id: \.self) { level in
                            Text(LocalizedStringKey("garment.formality.\(level)")).tag(Optional(level))
                        }
                    }
                }
                Section("garment.purchase") {
                    TextField("garment.brand", text: $form.details.brand)
                    TextField("garment.price", text: $form.price).keyboardType(.decimalPad)
                    Text("garment.priceHint").font(.footnote)
                    Toggle("garment.hasDate", isOn: Binding(
                        get: { form.details.purchasedOn != nil },
                        set: { form.details.purchasedOn = $0 ? GarmentDetails.dateFormatter.string(from: Date()) : nil }
                    ))
                    if form.details.purchasedOn != nil {
                        DatePicker("garment.date", selection: Binding(
                            get: { form.details.purchasedOn.flatMap { GarmentDetails.dateFormatter.date(from: $0) } ?? Date() },
                            set: { form.details.purchasedOn = GarmentDetails.dateFormatter.string(from: $0) }
                        ), displayedComponents: .date)
                        .environment(\.timeZone, TimeZone(secondsFromGMT: 0)!)
                        .environment(\.calendar, Calendar(identifier: .gregorian))
                    }
                }
                Section {
                    if let error { Text(LocalizedStringKey(error)).foregroundStyle(.red) }
                    Button("garment.save") {
                        do {
                            let details = try form.validated()
                            if save(details) { dismiss() } else { error = "import.storageFailed" }
                        } catch GarmentFormError.price { error = "garment.invalidPrice" }
                        catch { error = "garment.invalidFields" }
                    }
                }
            }
            .navigationTitle("garment.title")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.cancel") { dismiss() }
                }
            }
        }
    }

    private func membership(_ value: String, in selection: Binding<Set<String>>) -> Binding<Bool> {
        Binding(get: { selection.wrappedValue.contains(value) }, set: { enabled in
            if enabled { selection.wrappedValue.insert(value) } else { selection.wrappedValue.remove(value) }
        })
    }
}
