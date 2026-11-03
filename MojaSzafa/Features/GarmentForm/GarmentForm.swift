import Foundation

/// Editable metadata for an account-scoped photo draft. No AI-only required fields.
struct GarmentForm: Codable, Equatable, Sendable {
    static let palette = ["black", "white", "grey", "beige", "brown", "red", "orange", "yellow", "green", "blue", "purple", "pink", "silver", "gold", "multicolor"]
    static let seasons = ["spring", "summer", "autumn", "winter"]
    var name = ""
    var category: APIv1.Category = .other
    var colors: [String] = []
    var pattern = ""
    var seasons: [String] = []
    var formality: Int?
    var brand = ""
    var priceGrosz: Int64?
    /// Calendar date, never an instant that shifts when the timezone changes.
    var purchasedOn: String?

    enum Validation: String, Error {
        case name = "garment.invalidName"
        case price = "garment.invalidPrice"
        case metadata = "garment.invalidMetadata"
        case date = "garment.invalidDate"
    }

    static func parsePrice(_ text: String) throws -> Int64? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { return nil }
        let parts = value.replacingOccurrences(of: ",", with: ".").split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count <= 2, !parts[0].isEmpty,
              parts.allSatisfy({ $0.allSatisfy({ $0 >= "0" && $0 <= "9" }) }),
              parts.count == 1 || (1...2).contains(parts[1].count),
              let whole = Int64(parts[0]) else { throw Validation.price }
        let fraction = parts.count == 2 ? Int64(String(parts[1]).padding(toLength: 2, withPad: "0", startingAt: 0))! : 0
        let (scaled, overflow) = whole.multipliedReportingOverflow(by: 100)
        let (result, additionOverflow) = scaled.addingReportingOverflow(fraction)
        guard !overflow, !additionOverflow else { throw Validation.price }
        return result
    }

    var priceText: String {
        guard let priceGrosz else { return "" }
        return "\(priceGrosz / 100).\(String(format: "%02lld", priceGrosz % 100))"
    }

    func validated() throws -> Self {
        var result = self
        result.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        result.brand = brand.trimmingCharacters(in: .whitespacesAndNewlines)
        result.pattern = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.name.isEmpty, result.name.unicodeScalars.count <= 200 else { throw Validation.name }
        guard priceGrosz.map({ $0 >= 0 }) ?? true else { throw Validation.price }
        guard brand.count <= 200, pattern.count <= 200,
              Set(colors).isSubset(of: Set(Self.palette)), Set(colors).count == colors.count,
              Set(seasons).isSubset(of: Set(Self.seasons)), Set(seasons).count == seasons.count,
              formality.map({ (1...5).contains($0) }) ?? true else { throw Validation.metadata }
        if let purchasedOn {
            let formatter = Self.dateFormatter()
            guard let date = formatter.date(from: purchasedOn), formatter.string(from: date) == purchasedOn else {
                throw Validation.date
            }
        }
        return result
    }

    static func dateFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return formatter
    }

    /// Explicitly applied suggestions never infer financial or purchase information.
    /// The caller may prefill these before presenting the form; every field stays editable.
    mutating func apply(_ suggestion: Suggestions) {
        category = suggestion.category
        colors = suggestion.colors
        pattern = suggestion.pattern
        seasons = suggestion.seasons
        formality = suggestion.formality
    }

    struct Suggestions: Sendable {
        let category: APIv1.Category
        let colors: [String]
        let pattern: String
        let seasons: [String]
        let formality: Int?
    }
}
