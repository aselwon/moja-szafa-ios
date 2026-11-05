import Foundation
import SwiftUI

/// Local import metadata. Money is integer grosz; purchase date is a calendar date, never an instant.
struct GarmentFormValue: Codable, Equatable, Sendable {
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

extension Garment {
    var editableValue: GarmentFormValue? {
        guard let metadata = formMetadata else { return nil }
        return GarmentFormValue(name: name, category: category, colors: metadata.colors,
            pattern: metadata.pattern, seasons: metadata.seasons, formality: metadata.formality,
            brand: metadata.brand, priceGrosz: priceGrosz, purchasedOn: metadata.purchasedOn)
    }
}

/// Only attributes AI is allowed to suggest. No price, brand or purchase date.
struct GarmentRecognition: Codable {
    let category: APIv1.Category
    let colors: [String]
    let pattern: String?
    let seasons: [String]
    let formality: Int?
    let confidence: Double
    let multiple_items: Bool

    static let patterns = ["plain", "stripes", "checks", "dots", "floral", "graphic", "animal", "other"]
    var requiresCorrection: Bool { confidence < 0.8 || category == .other || multiple_items }

    /// Decode the private, validated worker result. Never trust review flags from the wire.
    static func decodeDraft(_ data: Data) throws -> Self {
        guard let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              envelope["schema_version"] as? String == "garment-recognition-v1",
              envelope["state"] as? String == "draft",
              let metadata = envelope["metadata"] as? [String: Any],
              Set(metadata.keys) == Set(["category", "colors", "pattern", "seasons", "formality", "confidence", "multiple_items"])
        else { throw GarmentFormInput.Validation.details }
        let value = try JSONDecoder().decode(Self.self, from: JSONSerialization.data(withJSONObject: metadata))
        guard value.confidence.isFinite, (0...1).contains(value.confidence),
              Set(value.colors).count == value.colors.count,
              Set(value.colors).isSubset(of: Set(GarmentFormInput.palette)),
              Set(value.seasons).count == value.seasons.count,
              Set(value.seasons).isSubset(of: Set(GarmentFormInput.seasons)),
              value.pattern == nil || patterns.contains(value.pattern!),
              value.formality == nil || (1...5).contains(value.formality!)
        else { throw GarmentFormInput.Validation.details }
        return value
    }

    var suggestions: GarmentSuggestions {
        // Never merge several garments into one draft. Keep the manual form usable.
        GarmentSuggestions(category: multiple_items ? .other : category,
                           colors: multiple_items ? [] : colors,
                           pattern: multiple_items ? nil : pattern,
                           seasons: multiple_items ? [] : seasons,
                           formality: multiple_items ? nil : formality,
                           requiresCorrection: requiresCorrection, multipleItems: multiple_items)
    }
}

struct GarmentSuggestions {
    var category: APIv1.Category
    var colors: [String]
    var pattern: String?
    var seasons: [String]
    var formality: Int?
    var requiresCorrection = false
    var multipleItems = false
}

struct GarmentFormInput {
    static let palette = ["black", "white", "gray", "beige", "brown", "red", "orange", "yellow", "green", "blue", "purple", "pink", "other"]
    static let seasons = ["spring", "summer", "autumn", "winter"]
    var requiresCorrection = false
    var multipleItems = false
    var reviewed = false
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
            requiresCorrection = suggestions.requiresCorrection
            multipleItems = suggestions.multipleItems
            category = suggestions.category
            colors = Set(suggestions.colors.filter { Self.palette.contains($0) })
            pattern = suggestions.pattern ?? ""
            seasons = Set(suggestions.seasons.filter { Self.seasons.contains($0) })
            formality = (1...5).contains(suggestions.formality ?? 0) ? suggestions.formality! : 0
        }
    }

    enum Validation: String, Error {
        case name = "garment.invalidName", price = "garment.invalidPrice"
        case review = "recognition.reviewRequired"
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
        guard !requiresCorrection || reviewed else { throw Validation.review }
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
    @State private var saving = false
    private let locked: Bool
    private let editingExisting: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var duplicates: DuplicatePhotoReview?
    private let duplicateReview: (() async -> DuplicatePhotoReview)?
    private let save: (GarmentFormValue) async throws -> Void

    init(value: GarmentFormValue?, suggestions: GarmentSuggestions? = nil,
         duplicateReview: (() async -> DuplicatePhotoReview)? = nil, locked: Bool = false, editingExisting: Bool = false,
         save: @escaping (GarmentFormValue) async throws -> Void) {
        _input = State(initialValue: GarmentFormInput(value: value, suggestions: suggestions))
        self.editingExisting = editingExisting
        self.locked = locked
        self.save = save
        self.duplicateReview = duplicateReview
    }

    var body: some View {
        NavigationStack {
            Form {
                if duplicateReview != nil {
                    Section("duplicate.title") {
                        if let duplicates {
                            if duplicates.incomplete { Text("duplicate.incomplete") }
                            if !duplicates.matches.isEmpty {
                                Text("duplicate.explanation")
                                ForEach(duplicates.matches) { match in
                                    VStack(alignment: .leading) {
                                        if let name = match.name { Text(name).font(.headline) }
                                        if let image = UIImage(data: match.image) {
                                            Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 160)
                                                .accessibilityLabel(Text("duplicate.preview"))
                                        }
                                    }
                                }
                            } else if !duplicates.incomplete { Text("duplicate.none") }
                        } else { ProgressView("duplicate.checking") }
                    }
                }

                Section {
                    Text(locked ? "import.pendingSave" : editingExisting ? "garment.editExplanation" : "garment.draftExplanation")
                    TextField("garment.name", text: $input.name)
                    Picker("garment.category", selection: $input.category) {
                        ForEach(APIv1.Category.allCases, id: \.self) { category in
                            Text(LocalizedStringKey("garment.category.\(category.rawValue)")).tag(category)
                        }
                    }
                    Text("garment.correction")
                    if input.requiresCorrection {
                        Text(LocalizedStringKey(input.multipleItems ? "recognition.multipleItems" : "recognition.lowConfidence"))
                        Toggle("recognition.reviewed", isOn: $input.reviewed)
                    }
                }
                .disabled(saving || locked)
                Section("garment.colors") {
                    ForEach(GarmentFormInput.palette, id: \.self) { color in
                        Toggle(LocalizedStringKey("garment.color.\(color)"), isOn: membership(color, in: $input.colors))
                    }
                }
                .disabled(saving || locked)
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
                .disabled(saving || locked)
                Section("garment.purchase") {
                    TextField("garment.brand", text: $input.brand)
                    TextField("garment.price", text: $input.price).keyboardType(.decimalPad)
                    Text("garment.priceHelp")
                    Toggle("garment.hasDate", isOn: $input.hasPurchaseDate)
                    if input.hasPurchaseDate {
                        DatePicker("garment.date", selection: $input.purchaseDate, in: ...Date(), displayedComponents: .date)
                    }
                }
                .disabled(saving || locked)
                Section {
                    if let error { Text(LocalizedStringKey(error)).foregroundStyle(Color("danger")) }
                    Button(LocalizedStringKey(duplicates?.matches.isEmpty == false ? "duplicate.keepBoth" : editingExisting ? "common.save" : "garment.save")) {
                        guard !saving else { return }
                        saving = true
                        Task {
                            defer { saving = false }
                            do { try await save(input.validated()); dismiss() }
                            catch let validation as GarmentFormInput.Validation { self.error = validation.rawValue }
                            catch OfflineError.conflict { self.error = "sync.conflict" }
                            catch OfflineError.pendingChange { self.error = "sync.pending" }
                            catch { self.error = "import.saveFailed" }
                        }
                    }.disabled(saving)
                    if saving { ProgressView("common.loading") }
                }
            }
            .navigationTitle("garment.title")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("common.cancel") { dismiss() }.disabled(saving) }
            }
        }
        .task {
            if let duplicateReview {
                let result = await duplicateReview()
                if !Task.isCancelled { duplicates = result }
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
