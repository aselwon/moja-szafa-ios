import XCTest
@testable import MojaSzafa

@MainActor
final class GarmentFormTests: XCTestCase {
    func testPriceUsesExactGroszAndPreservesMissingVersusZero() throws {
        XCTAssertNil(try GarmentForm.parsePrice("  "))
        XCTAssertEqual(try GarmentForm.parsePrice("0"), 0)
        XCTAssertEqual(try GarmentForm.parsePrice("800,01"), 80001)
        XCTAssertEqual(try GarmentForm.parsePrice("1.2"), 120)
        XCTAssertEqual(try GarmentForm.parsePrice("92233720368547758.07"), Int64.max)
        for text in ["-1", "+1", "1.234", "1,2.3", "1e2", "NaN", "1.", ".2", "1 000", "92233720368547758.08", "9223372036854775808"] {
            XCTAssertThrowsError(try GarmentForm.parsePrice(text), text)
        }
        var form = GarmentForm()
        form.priceGrosz = Int64.max
        XCTAssertEqual(try GarmentForm.parsePrice(form.priceText), Int64.max)
    }

    func testValidationAndManualCorrectionOfSuggestions() throws {
        var form = GarmentForm()
        XCTAssertThrowsError(try form.validated())
        form.name = "  Shirt  "
        form.brand = "Known brand"
        form.priceGrosz = 0
        form.purchasedOn = "2024-02-29"
        form.apply(.init(category: .dress, colors: ["red"], pattern: "stripes", seasons: ["winter"], formality: 5))
        form.category = .top
        form.colors = ["blue", "white"]
        form.pattern = "plain"
        form.seasons = ["summer"]
        form.formality = 1
        let result = try form.validated()
        XCTAssertEqual(result.name, "Shirt")
        XCTAssertEqual(result.category, .top)
        XCTAssertEqual(result.colors, ["blue", "white"])
        XCTAssertEqual(result.pattern, "plain")
        XCTAssertEqual(result.seasons, ["summer"])
        XCTAssertEqual(result.formality, 1)
        XCTAssertEqual(result.brand, "Known brand")
        XCTAssertEqual(result.priceGrosz, 0)
        XCTAssertEqual(result.purchasedOn, "2024-02-29")
        form.purchasedOn = "2025-02-29"
        XCTAssertThrowsError(try form.validated())
        form.purchasedOn = nil
        form.formality = 6
        XCTAssertThrowsError(try form.validated())
        form.formality = nil
        form.colors = ["invalid"]
        XCTAssertThrowsError(try form.validated())
    }

    func testDraftPersistsAcrossReopenAndIsRemovedWithPhoto() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID()
        try Data().write(to: directory.appendingPathComponent(id.uuidString).appendingPathExtension("jpg"))
        let model = PhotoImportModel(directory: directory)
        var form = GarmentForm()
        form.name = "Shirt"
        form.colors = ["white"]
        form.priceGrosz = 0
        XCTAssertTrue(model.saveGarmentForm(form, for: id))
        let reopened = PhotoImportModel(directory: directory)
        XCTAssertEqual(try reopened.garmentForm(for: id), form)
        var invalid = form
        invalid.name = " "
        XCTAssertFalse(reopened.saveGarmentForm(invalid, for: id))
        XCTAssertEqual(try reopened.garmentForm(for: id), form)
        XCTAssertFalse(reopened.saveGarmentForm(form, for: UUID()))
        reopened.remove(id)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    func testCorruptDraftIsNotSilentlyReplaced() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID()
        try Data("broken".utf8).write(to: directory.appendingPathComponent(id.uuidString).appendingPathExtension("json"))
        XCTAssertThrowsError(try PhotoImportModel(directory: directory).garmentForm(for: id))
    }
}
