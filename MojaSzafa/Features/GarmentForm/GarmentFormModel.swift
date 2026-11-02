import Combine
import Foundation

/// AI can only prefill descriptive attributes; purchase facts remain user input.
struct GarmentSuggestions: Equatable, Sendable {
    let category: APIv1.Category
    let colors: [String]
    let pattern: String?
    let seasons: [String]
    let formality: Int?
}

struct GarmentFormValues: Equatable {
    var name = ""
    var category: APIv1.Category = .other
    var colors: [String] = []
    var pattern = ""
    var seasons: [String] = []
    var formality = 0
    var brand = ""
    var price = ""
    var purchasedOn: String?

    init(suggestions: GarmentSuggestions? = nil) {
        if let suggestions {
            category = suggestions.category
            colors = suggestions.colors
            pattern = suggestions.pattern ?? ""
            seasons = suggestions.seasons
            formality = suggestions.formality ?? 0
        }
    }

    enum Validation: String, Error { case name, price, metadata, date }

    /// Accept Polish/English decimal separators, never grouping or rounding.
    /// Construct the integer directly so Int64.max and overflow are exact.
    static func grosz(_ input: String) throws -> Int64? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return nil }
        let parts = text.replacingOccurrences(of: ",", with: ".").split(separator: ".", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), !parts[0].isEmpty,
              parts.allSatisfy({ $0.allSatisfy({ $0 >= "0" && $0 <= "9" }) }),
              parts.count == 1 || (1...2).contains(parts[1].count) else { throw Validation.price }
        let fraction = parts.count == 1 ? "00" : String(parts[1]) + (parts[1].count == 1 ? "0" : "")
        guard let value = Int64(String(parts[0]) + fraction) else { throw Validation.price }
        return value
    }

    static func dayFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return formatter
    }

    static func validDay(_ value: String) -> Bool {
        let formatter = dayFormatter()
        guard value.count == 10, let date = formatter.date(from: value) else { return false }
        return formatter.string(from: date) == value
    }

    func fields() throws -> APIv1.GarmentFields {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty, cleanName.unicodeScalars.count <= 200 else { throw Validation.name }
        let amount = try Self.grosz(price)
        if let purchasedOn, !Self.validDay(purchasedOn) { throw Validation.date }
        func optional(_ value: String) -> String? {
            let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return clean.isEmpty ? nil : clean
        }
        let result = APIv1.GarmentFields(name: cleanName, category: category, priceGrosz: amount,
            availability: .available, colors: colors, pattern: optional(pattern), seasons: seasons,
            formality: formality == 0 ? nil : formality, brand: optional(brand), purchasedOn: purchasedOn)
        do { try result.validate() } catch { throw Validation.metadata }
        return result
    }
}

@MainActor
final class GarmentFormModel: ObservableObject {
    @Published var values: GarmentFormValues
    @Published private(set) var saving = false
    @Published private(set) var errorKey: String?
    let hasSuggestions: Bool
    let id: UUID
    private let repository: any WardrobeRepository

    init(id: UUID, repository: any WardrobeRepository, suggestions: GarmentSuggestions? = nil) {
        self.id = id
        self.repository = repository
        values = GarmentFormValues(suggestions: suggestions)
        hasSuggestions = suggestions != nil
    }

    func save() async -> Bool {
        guard !saving else { return false }
        saving = true
        defer { saving = false }
        do {
            let fields = try values.fields()
            try await repository.saveForm(id: id, fields: fields)
            errorKey = nil
            return true
        } catch let error as GarmentFormValues.Validation {
            errorKey = "garment.error.\(error.rawValue)"
        } catch {
            errorKey = "garment.error.save"
        }
        return false
    }
}
