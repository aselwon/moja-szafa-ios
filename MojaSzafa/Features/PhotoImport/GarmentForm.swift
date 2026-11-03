import Foundation
import SwiftUI

/// Local import metadata. Money is integer grosz; purchase date is a calendar date, never an instant.
struct GarmentFormValue: Codable, Equatable {
    var name: String
    var category: APIv1.Category
    var colors: [String]
    var pattern: String?
    var seasons: [String]
    var formality: Int?
    var brand: String?
    var priceGrosz: Int64?
    var purchasedOn: String?
}

/// Only attributes AI is allowed to suggest. No price, brand or purchase date.
struct GarmentSuggestions {
    var category: APIv1.Category
    var colors: [String]
    var pattern: String?
    var seasons: [String]
    var formality: Int?
}

struct GarmentFormInput {
    static let palette = ["black", "white", "gray", "beige", "brown", "red", "orange", "yellow", "green", "blue", "purple", "pink", "other"]
    static let seasons = ["spring", "summer", "autumn", "winter"]
    var name = ""
    var category: APIv1.Category = .other
    var colors: Set<String> = []
    var pattern = ""
    var seasons: Set<String> = []
    var formality = 0
    var brand = ""
    var price = ""
    var hasPurchaseDate = false
    var purchaseDate = Date()

    init(value: GarmentFormValue? = nil, suggestions: GarmentSuggestions? = nil) {
        if let value {
            name = value.name; category = value.category; colors = Set(value.colors)
            pattern = value.pattern ?? ""; seasons = Set(value.seasons); formality = value.formality ?? 0
            brand = value.brand ?? ""
            if let grosz = value.priceGrosz { price = "\(grosz / 100).\(String(format: "%02lld", grosz % 100))" }
            if let day = value.purchasedOn, let date = Self.dateFormatter.date(from: day) {
                hasPurchaseDate = true; purchaseDate = date
            }
        } else if let suggestions {
            category = suggestions.category
            colors = Set(suggestions.colors.filter { Self.palette.contains($0) })
            pattern = suggestions.pattern ?? ""
            seasons = Set(suggestions.seasons.filter { Self.seasons.contains($0) })
            formality = (1...5).contains(suggestions.formality ?? 0) ? suggestions.formality! : 0
        }
    }

    enum Validation: String, Error {
        case name = "garment.invalidName", price = "garment.invalidPrice"
        case details = "garment.invalidDetails", date = "garment.invalidDate"
    }

    /// Accept PL/EN decimal separators, reject grouping, signs, exponents and rounding.
    static func grosz(_ input: String) throws -> Int64? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return nil }
        let parts = text.replacingOccurrences(of: ",", with: ".").split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count <= 2, !parts[0].isEmpty,
              parts.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } }),
              parts.count == 1 || parts[1].count <= 2,
              let whole = Int64(parts[0]) else { throw Validation.price }
        let fraction = parts.count == 2 ? Int64(parts[1])! * (parts[1].count == 1 ? 10 : 1) : 0
        let (scaled, overflow) = whole.multipliedReportingOverflow(by: 100)
        let (result, additionOverflow) = scaled.addingReportingOverflow(fraction)
        guard !overflow, !additionOverflow else { throw Validation.price }
        return result
    }

    func validated(now: Date = Date()) throws -> GarmentFormValue {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, trimmedName.unicodeScalars.count <= 200 else { throw Validation.name }
        guard brand.unicodeScalars.count <= 200, pattern.unicodeScalars.count <= 200,
              colors.isSubset(of: Set(Self.palette)), seasons.isSubset(of: Set(Self.seasons)),
              (0...5).contains(formality) else { throw Validation.details }
        guard !hasPurchaseDate || Calendar.current.startOfDay(for: purchaseDate) <= Calendar.current.startOfDay(for: now)
        else { throw Validation.date }
        func optional(_ text: String) -> String? {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
        return GarmentFormValue(name: trimmedName, category: category, colors: colors.sorted(),
                                pattern: optional(pattern), seasons: seasons.sorted(),
                                formality: formality == 0 ? nil : formality, brand: optional(brand),
                                priceGrosz: try Self.grosz(price),
                                purchasedOn: hasPurchaseDate ? Self.dateFormatter.string(from: purchaseDate) : nil)
    }

    private static var dateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }
}

struct GarmentFormView: View {
    @State private var input: GarmentFormInput
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    private let save: (GarmentFormValue) throws -> Void

    init(value: GarmentFormValue?, suggestions: GarmentSuggestions? = nil,
         save: @escaping (GarmentFormValue) throws -> Void) {
        _input = State(initialValue: GarmentFormInput(value: value, suggestions: suggestions))
        self.save = save
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("garment.draftExplanation")
                    TextField("garment.name", text: $input.name)
                    Picker("garment.category", selection: $input.category) {
                        ForEach(APIv1.Category.allCases, id: \.self) { category in
                            Text(LocalizedStringKey("garment.category.\(category.rawValue)")).tag(category)
                        }
                    }
                    Text("garment.correction")
                }
                Section("garment.colors") {
                    ForEach(GarmentFormInput.palette, id: \.self) { color in
                        Toggle(LocalizedStringKey("garment.color.\(color)"), isOn: membership(color, in: $input.colors))
                    }
                }
                Section("garment.details") {
                    TextField("garment.pattern", text: $input.pattern)
                    ForEach(GarmentFormInput.seasons, id: \.self) { season in
                        Toggle(LocalizedStringKey("garment.season.\(season)"), isOn: membership(season, in: $input.seasons))
                    }
                    Picker("garment.formality", selection: $input.formality) {
                        ForEach(0...5, id: \.self) { level in
                            Text(LocalizedStringKey("garment.formality.\(level)")).tag(level)
                        }
                    }
                }
                Section("garment.purchase") {
                    TextField("garment.brand", text: $input.brand)
                    TextField("garment.price", text: $input.price).keyboardType(.decimalPad)
                    Text("garment.priceHelp")
                    Toggle("garment.hasDate", isOn: $input.hasPurchaseDate)
                    if input.hasPurchaseDate {
                        DatePicker("garment.date", selection: $input.purchaseDate, in: ...Date(), displayedComponents: .date)
                    }
                }
                Section {
                    if let error { Text(LocalizedStringKey(error)).foregroundStyle(Color("danger")) }
                    Button("garment.save") {
                        do { try save(input.validated()); dismiss() }
                        catch let validation as GarmentFormInput.Validation { self.error = validation.rawValue }
                        catch { self.error = "import.storageFailed" }
                    }
                }
            }
            .navigationTitle("garment.title")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("common.cancel") { dismiss() } }
            }
        }
        .interactiveDismissDisabled()
    }

    private func membership(_ value: String, in set: Binding<Set<String>>) -> Binding<Bool> {
        Binding(get: { set.wrappedValue.contains(value) }, set: { selected in
            if selected { set.wrappedValue.insert(value) } else { set.wrappedValue.remove(value) }
        })
    }
}
