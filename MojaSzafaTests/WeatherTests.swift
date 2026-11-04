import XCTest
@testable import MojaSzafa

@MainActor
final class WeatherTests: XCTestCase {
    func testGenerationReplayPreservesWeatherWithoutLocationAndOldIntentsDecode() throws {
        let hint = GenerationWeatherContext(temperature_celsius: -5.5, source: "manual", valid_until: nil)
        let request = GenerationRequest(operation_id: UUID(), count: 3, weather: hint)
        let data = try JSONEncoder().encode(request)
        XCTAssertEqual(try JSONDecoder().decode(GenerationRequest.self, from: data), request)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let weather = try XCTUnwrap(object["weather"] as? [String: Any])
        XCTAssertEqual(Set(weather.keys), ["source", "temperature_celsius"])
        let oldRequest = GenerationRequest(operation_id: UUID(), count: 3)
        let oldData = try JSONEncoder().encode(oldRequest)
        XCTAssertNil(try JSONDecoder().decode(GenerationRequest.self, from: oldData).weather)
    }
    func testAuthenticatedForecastUsesCoarseBodyAndFixedAttribution() async throws {
        let client = try APIClient(baseURL: URL(string: "https://gateway.example/rest/v1")!,
            transport: ForecastTransport()) { "valid-session" }
        let result = try await client.forecast(latitude: 52.2297, longitude: 21.0122)
        XCTAssertEqual(result.celsius, 8.5)
        XCTAssertEqual(result.source, "MET Norway")
        XCTAssertNil(result.attributionImageURL)
        XCTAssertEqual(result.updatedAt, ISO8601DateFormatter().date(from: "2026-11-04T09:17:25Z"))
    }
    private let city = WeatherCity(name: "Tokyo", latitude: 35.7, longitude: 139.7,
                                   timeZone: TimeZone(identifier: "Asia/Tokyo")!)

    func testManualCityNeedsNoLocationAndPreservesCityTimeZone() async {
        let service = WeatherFixture()
        service.results = [city]
        let model = WeatherModel(service: service)
        model.query = "Tokyo"
        await model.search()
        XCTAssertEqual(model.cities, [city])
        await model.select(city)
        XCTAssertEqual(service.locationRequests, 0)
        XCTAssertEqual(model.context()?.timeZoneIdentifier, "Asia/Tokyo")
        XCTAssertEqual(model.context()?.source, .forecast)
        XCTAssertNotNil(model.forecast?.updatedAt)
    }

    func testDenialAndOfflineDoNotPreventManualContextOrNoContext() async {
        let service = WeatherFixture()
        let model = WeatherModel(service: service)
        await model.locate()
        XCTAssertEqual(model.message, "weather.locationError")
        XCTAssertNil(model.context())
        service.offline = true
        await model.select(city)
        XCTAssertNil(model.forecast)
        XCTAssertEqual(model.message, "weather.forecastError")
        model.useManualTemperature = true
        model.manualTemperature = "-5,5"
        XCTAssertEqual(model.context()?.temperatureCelsius, -5.5)
        XCTAssertEqual(model.context()?.source, .manual)
        for invalid in ["nan", "inf", "61", "-81", "", "cold"] {
            model.manualTemperature = invalid
            XCTAssertNil(model.context())
        }
    }

    func testStaleForecastAndCityChangeCannotReuseOldTemperature() async {
        let service = WeatherFixture()
        let model = WeatherModel(service: service)
        await model.select(city)
        let updated = model.forecast!.updatedAt
        XCTAssertNil(model.context(now: updated.addingTimeInterval(3601)))
        service.offline = true
        await model.select(WeatherCity(name: "Warsaw", latitude: 52.2, longitude: 21,
                                      timeZone: TimeZone(identifier: "Europe/Warsaw")!))
        XCTAssertNil(model.context())
        XCTAssertNil(model.forecast)
        model.clear()
        XCTAssertNil(model.city)
        XCTAssertFalse(model.busy)
    }

    func testClearedScreenDiscardsLateForecast() async {
        let service = WeatherFixture()
        service.suspend = true
        let model = WeatherModel(service: service)
        let request = Task { await model.select(city) }
        while service.pending == nil { await Task.yield() }
        model.clear()
        service.pending?.resume(returning: service.result)
        await request.value
        XCTAssertNil(model.city)
        XCTAssertNil(model.forecast)
        XCTAssertNil(model.context())
    }

    func testProviderIssueTimeCanPrecedeCurrentForecastWithoutInventingFreshness() async {
        let service = WeatherFixture()
        let now = Date()
        service.fixedResult = CityForecast(celsius: 8.5, validAt: now.addingTimeInterval(1800),
            updatedAt: now.addingTimeInterval(-3 * 3600),
            attributionURL: URL(string: "https://api.met.no/")!,
            attributionImageURL: URL(string: "https://example.invalid/mark")!)
        let model = WeatherModel(service: service)
        await model.select(city)
        XCTAssertEqual(model.context(now: now)?.temperatureCelsius, 8.5)
        XCTAssertEqual(model.forecast?.updatedAt, service.fixedResult?.updatedAt)
        XCTAssertNil(model.context(now: now.addingTimeInterval(1801)))
        XCTAssertNil(model.context(now: now.addingTimeInterval(-3 * 3600)))
    }
}

private struct ForecastTransport: APITransport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        XCTAssertEqual(request.url?.absoluteString, "https://gateway.example/v1/weather")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer valid-session")
        let body = try JSONDecoder().decode([String: Double].self, from: request.httpBody!)
        XCTAssertEqual(body, ["latitude": 52.23, "longitude": 21.01])
        let data = Data(#"{"data":{"celsius":8.5,"validAt":"2026-11-04T12:00:00Z","updatedAt":"2026-11-04T09:17:25Z","source":"MET Norway","attributionURL":"https://api.met.no/","licenseURL":"https://creativecommons.org/licenses/by/4.0/"}}"#.utf8)
        return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

@MainActor
private final class WeatherFixture: CityWeatherService {
    var results: [WeatherCity] = []
    var locationRequests = 0
    var offline = false
    var suspend = false
    var pending: CheckedContinuation<CityForecast, any Error>?
    var fixedResult: CityForecast?
    var result: CityForecast {
        fixedResult ?? CityForecast(celsius: 12, validAt: Date().addingTimeInterval(1800), updatedAt: Date(),
                     attributionURL: URL(string: "https://example.invalid/legal")!,
                     attributionImageURL: URL(string: "https://example.invalid/mark")!)
    }
    func cancelLocationRequest() {}
    func cities(named query: String) async throws -> [WeatherCity] { results }
    func cityAtCurrentLocation() async throws -> WeatherCity {
        locationRequests += 1
        throw CityWeatherError.unavailable
    }
    func forecast(for city: WeatherCity) async throws -> CityForecast {
        if offline { throw URLError(.notConnectedToInternet) }
        if suspend { return try await withCheckedThrowingContinuation { pending = $0 } }
        return result
    }
}
