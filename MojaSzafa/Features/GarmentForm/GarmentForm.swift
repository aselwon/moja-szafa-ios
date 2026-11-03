import Foundation

/// Local import metadata. Purchase facts are never supplied by AI.
struct GarmentDetails: Codable, Equatable, Sendable {
    var name = ""
    var category: APIv1.Category = .other
    var colors: Set<String> = []
    var pattern = ""
    var seasons: Set<String> = []
    var formality: Int?
    var brand = ""
    var priceGrosz: Int64?
    /// Calendar date, not an instant: preserves the selected day across time zones.
    var purchasedOn: String?

    static let palette = ["black", "white", "gray", "beige", "brown", "red", "orange", "yellow", "green", "blue", "purple", "pink", "multicolor"]
    static let seasonOptions = ["spring", "summer", "autumn", "winter"]

    func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name.unicodeScalars.count <= 200, brand.unicodeScalars.count <= 200,
              pattern.unicodeScalars.count <= 200,
              colors.isSubset(of: Set(Self.palette)), seasons.isSubset(of: Set(Self.seasonOptions)),
              formality.map({ (1...5).contains($0) }) ?? true,
              priceGrosz.map({ $0 >= 0 }) ?? true else { throw GarmentFormError.fields }
        if let purchasedOn {
            guard let date = Self.dateFormatter.date(from: purchasedOn),
                  Self.dateFormatter.string(from: date) == purchasedOn else { throw GarmentFormError.fields }
        }
    }

    static var dateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return formatter
    }
}

enum GarmentFormError: Error { case price, fields }

struct GarmentSuggestions: Sendable {
    var category: APIv1.Category?
    var colors: Set<String>?
    var pattern: String?
    var seasons: Set<String>?
    var formality: Int?
}

struct GarmentFormState {
    var details: GarmentDetails
    var price: String
    let hasSuggestions: Bool

    /// Suggestions seed the form once. Later edits are always authoritative.
    init(details: GarmentDetails = GarmentDetails(), suggestions: GarmentSuggestions? = nil) {
        self.details = details
        hasSuggestions = suggestions != nil
        if let suggestions {
            if let category = suggestions.category { self.details.category = category }
            if let colors = suggestions.colors { self.details.colors = colors.intersection(GarmentDetails.palette) }
            if let pattern = suggestions.pattern { self.details.pattern = pattern }
            if let seasons = suggestions.seasons { self.details.seasons = seasons.intersection(GarmentDetails.seasonOptions) }
            if let formality = suggestions.formality, (1...5).contains(formality) { self.details.formality = formality }
        }
        price = details.priceGrosz.map { "\($0 / 100)." + String(format: "%02lld", $0 % 100) } ?? ""
    }

    func validated() throws -> GarmentDetails {
        var result = details
        result.name = result.name.trimmingCharacters(in: .whitespacesAndNewlines)
        result.brand = result.brand.trimmingCharacters(in: .whitespacesAndNewlines)
        result.pattern = result.pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        result.priceGrosz = try Self.parsePrice(price)
        try result.validate()
        return result
    }

    /// Accept PL/EN decimal separators, no grouping, signs, exponents or rounding.
    static func parsePrice(_ input: String) throws -> Int64? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return nil }
        let parts = text.replacingOccurrences(of: ",", with: ".").split(separator: ".", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), !parts[0].isEmpty,
              parts.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy({ (48...57).contains($0) }) }),
              parts.count == 1 || parts[1].count <= 2,
              let whole = Int64(parts[0]) else { throw GarmentFormError.price }
        let fraction = parts.count == 2 ? Int64(parts[1])! * (parts[1].count == 1 ? 10 : 1) : 0
        let (base, overflow) = whole.multipliedReportingOverflow(by: 100)
        let (total, sumOverflow) = base.addingReportingOverflow(fraction)
        guard !overflow, !sumOverflow else { throw GarmentFormError.price }
        return total
    }
}
