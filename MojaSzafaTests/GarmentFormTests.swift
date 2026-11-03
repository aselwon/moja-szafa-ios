import XCTest
@testable import MojaSzafa

final class GarmentFormTests: XCTestCase {
    func testExactPriceParsingAndLimits() throws {
        XCTAssertNil(try GarmentFormState.parsePrice("  "))
        for (input, expected) in [("0", Int64(0)), ("0,00", 0), ("800", 80000),
                                  ("12,3", 1230), ("12.34", 1234),
                                  ("92233720368547758.07", Int64.max)] {
            XCTAssertEqual(try GarmentFormState.parsePrice(input), expected)
        }
        for input in ["-1", "+1", "1e2", "NaN", "1.001", "1,2.3", "1 000", "1.", ".5",
                      "92233720368547758.08", "9999999999999999999999999"] {
            XCTAssertThrowsError(try GarmentFormState.parsePrice(input), input)
        }
    }

    func testSuggestionsAreCorrectableAndDoNotInventPurchaseFacts() throws {
        let suggestions = GarmentSuggestions(category: .dress, colors: ["red"], pattern: "stripes",
                                             seasons: ["summer"], formality: 5)
        var form = GarmentFormState(suggestions: suggestions)
        XCTAssertTrue(form.hasSuggestions)
        XCTAssertNil(form.details.priceGrosz)
        XCTAssertNil(form.details.purchasedOn)
        XCTAssertEqual(form.details.brand, "")
        XCTAssertEqual(form.details.category, .dress)
        form.details.name = "  Shirt  "
        form.details.category = .top
        form.details.colors = ["blue", "white"]
        form.details.pattern = "plain"
        form.details.seasons = ["winter"]
        form.details.formality = 1
        form.details.brand = "Example"
        form.details.purchasedOn = "2024-02-29"
        form.price = "0"
        let saved = try form.validated()
        XCTAssertEqual(saved.name, "Shirt")
        XCTAssertEqual(saved.category, .top)
        XCTAssertEqual(saved.colors, ["blue", "white"])
        XCTAssertEqual(saved.pattern, "plain")
        XCTAssertEqual(saved.seasons, ["winter"])
        XCTAssertEqual(saved.formality, 1)
        XCTAssertEqual(saved.brand, "Example")
        XCTAssertEqual(saved.priceGrosz, 0)
        XCTAssertEqual(saved.purchasedOn, "2024-02-29")
        XCTAssertEqual(try GarmentFormState(details: saved).validated(), saved)
    }

    func testManualFallbackAndValidation() throws {
        var form = GarmentFormState()
        XCTAssertFalse(form.hasSuggestions)
        XCTAssertThrowsError(try form.validated())
        form.details.name = "Manual garment"
        XCTAssertNil(try form.validated().priceGrosz)
        form.details.purchasedOn = "2023-02-29"
        XCTAssertThrowsError(try form.validated())
        form.details.purchasedOn = nil
        form.details.formality = 6
        XCTAssertThrowsError(try form.validated())
        form.details.formality = nil
        form.details.colors = ["invalid"]
        XCTAssertThrowsError(try form.validated())
        form.details.colors = []
        form.details.name = String(repeating: "a", count: 201)
        XCTAssertThrowsError(try form.validated())
    }

    @MainActor
    func testDraftPersistenceIsolationRemovalAndFailedSave() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let first = UUID(), second = UUID()
        for id in [first, second] {
            try Data().write(to: directory.appendingPathComponent(id.uuidString).appendingPathExtension("jpg"))
        }
        let model = PhotoImportModel(directory: directory)
        var form = GarmentFormState()
        form.details.name = "Coat"
        form.details.category = .outerwear
        form.details.colors = ["black"]
        form.details.pattern = "plain"
        form.details.seasons = ["winter", "autumn"]
        form.details.formality = 3
        form.details.brand = "Example"
        form.details.purchasedOn = "2020-01-02"
        form.price = "125,99"
        let details = try form.validated()
        XCTAssertTrue(model.saveDetails(details, for: first))
        let restored = PhotoImportModel(directory: directory)
        XCTAssertEqual(restored.drafts.first { $0.id == first }?.details, details)
        XCTAssertEqual(restored.drafts.first { $0.id == second }?.details, GarmentDetails())
        XCTAssertFalse(model.saveDetails(GarmentDetails(), for: first))
        XCTAssertEqual(model.drafts.first { $0.id == first }?.details, details)
        let metadata = directory.appendingPathComponent(first.uuidString).appendingPathExtension("json")
        try FileManager.default.removeItem(at: metadata)
        try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: false)
        var changed = details
        changed.name = "Changed"
        XCTAssertFalse(model.saveDetails(changed, for: first))
        XCTAssertEqual(model.drafts.first { $0.id == first }?.details, details)
        try FileManager.default.removeItem(at: metadata)
        XCTAssertTrue(model.saveDetails(details, for: first))
        model.remove(first)
        XCTAssertFalse(FileManager.default.fileExists(atPath: metadata.path))
        XCTAssertEqual(PhotoImportModel(directory: directory).drafts.map(\.id), [second])
    }
}
