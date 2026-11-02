import XCTest
@testable import MojaSzafa

@MainActor
final class GarmentFormTests: XCTestCase {
    func testPriceIsExactAndUnknownDiffersFromZero() throws {
        XCTAssertNil(try GarmentFormValues.grosz("  "))
        XCTAssertEqual(try GarmentFormValues.grosz("0"), 0)
        XCTAssertEqual(try GarmentFormValues.grosz("0,00"), 0)
        XCTAssertEqual(try GarmentFormValues.grosz("800"), 80000)
        XCTAssertEqual(try GarmentFormValues.grosz(" 12,3 "), 1230)
        XCTAssertEqual(try GarmentFormValues.grosz("12.34"), 1234)
        XCTAssertEqual(try GarmentFormValues.grosz("92233720368547758.07"), Int64.max)
        for invalid in ["-1", "+1", "1e2", "NaN", "1,234", "1.234", "1 000", "1,2.3", ".50", "1.", "１２", "92233720368547758.08"] {
            XCTAssertThrowsError(try GarmentFormValues.grosz(invalid), invalid)
        }
    }

    func testSuggestionsCanAllBeCorrectedWithoutInventingPurchaseFacts() throws {
        var values = GarmentFormValues(suggestions: GarmentSuggestions(category: .top, colors: ["red"],
            pattern: "stripes", seasons: ["summer"], formality: 1))
        XCTAssertTrue(values.brand.isEmpty)
        XCTAssertTrue(values.price.isEmpty)
        XCTAssertNil(values.purchasedOn)
        values.name = "  Dress  "
        values.category = .dress
        values.colors = ["blue", "white"]
        values.pattern = "plain"
        values.seasons = ["winter"]
        values.formality = 4
        values.brand = "  Brand  "
        values.price = "0"
        values.purchasedOn = "2024-02-29"
        let fields = try values.fields()
        XCTAssertEqual(fields.name, "Dress")
        XCTAssertEqual(fields.category, .dress)
        XCTAssertEqual(fields.colors, ["blue", "white"])
        XCTAssertEqual(fields.pattern, "plain")
        XCTAssertEqual(fields.seasons, ["winter"])
        XCTAssertEqual(fields.formality, 4)
        XCTAssertEqual(fields.brand, "Brand")
        XCTAssertEqual(fields.priceGrosz, 0)
        XCTAssertEqual(fields.purchasedOn, "2024-02-29")
        XCTAssertEqual(try JSONDecoder().decode(APIv1.GarmentFields.self, from: JSONEncoder().encode(fields)), fields)
    }

    func testValidationAndLegacyPayloadCompatibility() throws {
        var values = GarmentFormValues()
        XCTAssertThrowsError(try values.fields())
        values.name = String(repeating: "a", count: 201)
        XCTAssertThrowsError(try values.fields())
        values.name = "Shirt"
        values.purchasedOn = "2025-02-29"
        XCTAssertThrowsError(try values.fields())
        values.purchasedOn = nil
        values.formality = 6
        XCTAssertThrowsError(try values.fields())
        values.formality = 0
        values.seasons = ["monsoon"]
        XCTAssertThrowsError(try values.fields())
        values.seasons = []
        values.colors = ["blue", "blue"]
        XCTAssertThrowsError(try values.fields())
        values.colors = []
        values.brand = String(repeating: "a", count: 201)
        XCTAssertThrowsError(try values.fields())
        values.brand = ""
        XCTAssertNil(try values.fields().priceGrosz)
        let old = Data(#"{"name":"Old","category":"top","price_grosz":null,"availability":"available"}"#.utf8)
        let decoded = try JSONDecoder().decode(APIv1.GarmentFields.self, from: old)
        XCTAssertNil(decoded.colors)
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? NSDictionary)
        XCTAssertEqual(encoded, try JSONSerialization.jsonObject(with: old) as? NSDictionary)
    }

    func testFailedSaveRetainsInputAndRetryUsesSameGarment() async throws {
        let repository = FormRepository()
        let model = GarmentFormModel(id: UUID(), repository: repository)
        let invalid = await model.save()
        XCTAssertFalse(invalid)
        XCTAssertEqual(model.errorKey, "garment.error.name")
        model.values.name = "Shirt"
        model.values.price = "0"
        let before = model.values
        let failed = await model.save()
        XCTAssertFalse(failed)
        XCTAssertEqual(model.values, before)
        XCTAssertEqual(model.errorKey, "garment.error.save")
        let saved = await model.save()
        XCTAssertTrue(saved)
        XCTAssertNil(model.errorKey)
        let ids = await repository.ids
        XCTAssertEqual(ids, [model.id, model.id])
    }
}

private actor FormRepository: WardrobeRepository {
    var ids: [UUID] = []
    func garments() async throws -> [Garment] { [] }
    func saveForm(id: UUID, fields: APIv1.GarmentFields) async throws {
        ids.append(id)
        if ids.count == 1 { throw OfflineError.storage }
    }
}
