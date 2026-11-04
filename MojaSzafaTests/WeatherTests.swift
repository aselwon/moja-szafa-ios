import XCTest
@testable import MojaSzafa

@MainActor
final class WeatherTests: XCTestCase {
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
