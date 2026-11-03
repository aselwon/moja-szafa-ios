import XCTest
@testable import MojaSzafa

final class GarmentFormTests: XCTestCase {
    func testExactMoneyAndMissingPrice() throws {
        XCTAssertNil(try GarmentFormInput.grosz(" \n"))
        let valid: [(String, Int64)] = [("0", 0), ("0,00", 0), ("800", 80000),
                                                  ("12,34", 1234), ("12.3", 1230),
                                                  ("92233720368547758.07", Int64.max)]
        for (text, expected) in valid {
            XCTAssertEqual(try GarmentFormInput.grosz(text), expected)
        }
        for text in ["-1", "+1", "1.001", "1,000", "1e3", "1 000", "1,2.3", ".5", "1.",
                     "NaN", "92233720368547758.08", "9223372036854775807"] {
            XCTAssertThrowsError(try GarmentFormInput.grosz(text), text)
        }
    }

    func testValidationAndOptionalFields() throws {
        var input = GarmentFormInput()
        XCTAssertThrowsError(try input.validated())
        input.name = String(repeating: "a", count: 201)
        XCTAssertThrowsError(try input.validated())
        input.name = "  Shirt \n"
        let result = try input.validated()
        XCTAssertEqual(result.name, "Shirt")
        XCTAssertNil(result.brand)
        XCTAssertNil(result.pattern)
        XCTAssertNil(result.priceGrosz)
        XCTAssertNil(result.purchasedOn)
        input.hasPurchaseDate = true
        input.purchaseDate = Date().addingTimeInterval(3 * 86400)
        XCTAssertThrowsError(try input.validated())
        input.hasPurchaseDate = false
        input.formality = 6
        XCTAssertThrowsError(try input.validated())
    }

    func testSuggestionsCanBeCorrectedAndDoNotReplaceSavedInput() throws {
        let suggestions = GarmentSuggestions(category: .top, colors: ["blue", "invalid"],
                                              pattern: "stripes", seasons: ["summer"], formality: 2)
        var input = GarmentFormInput(suggestions: suggestions)
        XCTAssertEqual(input.colors, ["blue"])
        XCTAssertTrue(input.brand.isEmpty)
        XCTAssertTrue(input.price.isEmpty)
        XCTAssertFalse(input.hasPurchaseDate)
        input.name = "Dress"; input.category = .dress; input.colors = ["red"]
        input.pattern = "plain"; input.seasons = ["winter"]; input.formality = 5
        input.brand = "My brand"; input.price = "0"; input.hasPurchaseDate = true
        let value = try input.validated()
        XCTAssertEqual(try GarmentFormInput(value: value, suggestions: suggestions).validated(), value)
        XCTAssertEqual(value.category, .dress)
        XCTAssertEqual(value.priceGrosz, 0)
        XCTAssertEqual(value.pattern, "plain")
        XCTAssertEqual(value.seasons, ["winter"])
    }

    private func recognitionData(confidence: Double = 0.9, multiple: Bool = false,
                                 extra: [String: Any] = [:]) throws -> Data {
        var metadata: [String: Any] = ["category": "top", "colors": ["blue"], "pattern": "plain",
                                      "seasons": ["summer"], "formality": 2,
                                      "confidence": confidence, "multiple_items": multiple]
        metadata.merge(extra) { _, new in new }
        return try JSONSerialization.data(withJSONObject: ["schema_version": "garment-recognition-v1",
                                                           "state": "draft", "metadata": metadata])
    }

    func testRecognitionRejectsInvalidMetadata() throws {
        for patch in ([["brand": "Invented"], ["price": 100], ["purchased_on": "2026-01-01"],
                                    ["category": "shirt"], ["colors": ["blue", "blue"]],
                                    ["colors": ["navy"]], ["pattern": "unknown"], ["seasons": ["all"]],
                                    ["formality": 6], ["confidence": 1.1], ["multiple_items": "false"]] as [[String: Any]]) {
            XCTAssertThrowsError(try GarmentRecognition.decodeDraft(recognitionData(extra: patch)))
        }
    }

    func testUncertainRecognitionRequiresReviewAndRemainsEditable() throws {
        let recognition = try GarmentRecognition.decodeDraft(recognitionData(confidence: 0.79))
        var input = GarmentFormInput(suggestions: recognition.suggestions)
        input.name = "Dress"
        XCTAssertThrowsError(try input.validated())
        input.category = .dress
        input.reviewed = true
        let value = try input.validated()
        XCTAssertEqual(value.category, .dress)
        XCTAssertNil(value.priceGrosz)
        XCTAssertNil(value.brand)
        XCTAssertNil(value.purchasedOn)
        XCTAssertFalse(try GarmentRecognition.decodeDraft(recognitionData(confidence: 0.8)).requiresCorrection)
    }

    func testMultipleItemsDoesNotCombineSuggestions() throws {
        let recognition = try GarmentRecognition.decodeDraft(recognitionData(multiple: true))
        var input = GarmentFormInput(suggestions: recognition.suggestions)
        XCTAssertEqual(input.category, .other)
        XCTAssertTrue(input.colors.isEmpty)
        XCTAssertTrue(input.pattern.isEmpty)
        XCTAssertTrue(input.seasons.isEmpty)
        input.name = "One garment"
        XCTAssertThrowsError(try input.validated())
        input.reviewed = true
        XCTAssertNoThrow(try input.validated())
    }

    @MainActor
    func testRecognitionPersistsSeparatelyWithoutOverwritingManualDraft() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let id = UUID()
        try Data().write(to: directory.appendingPathComponent(id.uuidString).appendingPathExtension("jpg"))
        let model = PhotoImportModel(directory: directory)
        try model.acceptRecognition(recognitionData(confidence: 0.1), for: id)
        XCTAssertNil(try model.garmentValue(for: id))
        let reopened = PhotoImportModel(directory: directory)
        XCTAssertTrue(try XCTUnwrap(reopened.recognitionSuggestions(for: id)).requiresCorrection)
        var input = GarmentFormInput(); input.name = "My shirt"; input.brand = "User brand"
        let value = try input.validated()
        try model.saveGarmentValue(value, for: id)
        try model.acceptRecognition(recognitionData(), for: id)
        XCTAssertEqual(try model.garmentValue(for: id), value)
        XCTAssertThrowsError(try model.acceptRecognition(recognitionData(), for: UUID()))
        XCTAssertTrue(model.acceptEdit(Data(), for: id))
        XCTAssertNil(try model.recognitionSuggestions(for: id))
        try model.acceptRecognition(recognitionData(), for: id)
        model.remove(id)
        XCTAssertNil(try model.recognitionSuggestions(for: id))
    }

    @MainActor
    func testDraftRoundTripIsolationRemovalAndWriteFailure() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let first = UUID(), second = UUID()
        for id in [first, second] {
            try Data().write(to: directory.appendingPathComponent(id.uuidString).appendingPathExtension("jpg"))
        }
        let model = PhotoImportModel(directory: directory)
        var input = GarmentFormInput()
        input.name = "Shirt"; input.price = "12,34"; input.colors = ["blue", "white"]
        let value = try input.validated()
        try model.saveGarmentValue(value, for: first)
        let reopened = PhotoImportModel(directory: directory)
        XCTAssertEqual(try reopened.garmentValue(for: first), value)
        XCTAssertNil(try reopened.garmentValue(for: second))
        XCTAssertThrowsError(try reopened.saveGarmentValue(value, for: UUID()))
        reopened.remove(first)
        XCTAssertNil(try reopened.garmentValue(for: first))
        XCTAssertEqual(reopened.drafts.map(\.id), [second])
        try FileManager.default.removeItem(at: directory)
        XCTAssertThrowsError(try reopened.saveGarmentValue(value, for: second))
    }
}
