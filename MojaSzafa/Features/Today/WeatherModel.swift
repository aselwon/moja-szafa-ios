import Foundation
import Observation
import CoreLocation
import WeatherKit

struct WeatherCity: Equatable, Sendable {
    let name: String
    let latitude: Double
    let longitude: Double
    let timeZone: TimeZone
}

struct CityForecast: Sendable {
    let celsius: Double
    let validAt: Date
    let updatedAt: Date
    let attributionURL: URL
    let attributionImageURL: URL
}

@MainActor
protocol CityWeatherService {
    func cancelLocationRequest()
    func cities(named query: String) async throws -> [WeatherCity]
    func cityAtCurrentLocation() async throws -> WeatherCity
    func forecast(for city: WeatherCity) async throws -> CityForecast
}

enum CityWeatherError: Error { case unavailable }

/// No background tracking, persistence or coordinate logging. Every location
/// request is initiated by a user action and bounded by a timeout.
@MainActor
final class AppleCityWeatherService: NSObject, CityWeatherService, @preconcurrency CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var pending: CheckedContinuation<CLLocation, any Error>?
    private var timeout: Task<Void, Never>?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
    }

    func cancelLocationRequest() { finish(.failure(CancellationError())) }

    func cities(named query: String) async throws -> [WeatherCity] {
        let places = try await CLGeocoder().geocodeAddressString(query)
        return places.compactMap(Self.city)
    }

    private static func city(_ place: CLPlacemark) -> WeatherCity? {
        guard let location = place.location, let zone = place.timeZone,
              let name = place.locality ?? place.name else { return nil }
        return WeatherCity(name: [name, place.administrativeArea, place.country].compactMap { $0 }.joined(separator: ", "),
                           latitude: location.coordinate.latitude, longitude: location.coordinate.longitude, timeZone: zone)
    }

    func cityAtCurrentLocation() async throws -> WeatherCity {
        let location: CLLocation = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard pending == nil else { continuation.resume(throwing: CityWeatherError.unavailable); return }
                pending = continuation
                timeout = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(20)) } catch { return }
                    self?.finish(.failure(CityWeatherError.unavailable))
                }
                switch manager.authorizationStatus {
                case .notDetermined: manager.requestWhenInUseAuthorization()
                case .authorizedAlways, .authorizedWhenInUse: manager.requestLocation()
                default: finish(.failure(CityWeatherError.unavailable))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(.failure(CancellationError())) }
        }
        try Task.checkCancellation()
        let places = try await CLGeocoder().reverseGeocodeLocation(location)
        guard let city = places.compactMap(Self.city).first else { throw CityWeatherError.unavailable }
        return city
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard pending != nil else { return }
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse: manager.requestLocation()
        case .denied, .restricted: finish(.failure(CityWeatherError.unavailable))
        default: break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last, location.horizontalAccuracy >= 0,
              abs(location.timestamp.timeIntervalSinceNow) < 120 else {
            finish(.failure(CityWeatherError.unavailable)); return
        }
        finish(.success(location))
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) { finish(.failure(error)) }

    private func finish(_ result: Result<CLLocation, any Error>) {
        let continuation = pending
        pending = nil
        timeout?.cancel(); timeout = nil
        manager.stopUpdatingLocation()
        continuation?.resume(with: result)
    }

    func forecast(for city: WeatherCity) async throws -> CityForecast {
        let service = WeatherService.shared
        let weather = try await service.weather(for: CLLocation(latitude: city.latitude, longitude: city.longitude))
        let attribution = try await service.attribution
        let now = Date()
        guard let hour = weather.hourlyForecast.forecast.first(where: { $0.date >= now }) else {
            throw CityWeatherError.unavailable
        }
        return CityForecast(celsius: hour.temperature.converted(to: .celsius).value,
                            validAt: hour.date, updatedAt: now, attributionURL: attribution.legalPageURL,
                            attributionImageURL: attribution.combinedMarkLightURL)
    }
}

/// Optional input for outfit ranking, never an eligibility or permission gate.
struct OutfitWeatherContext: Equatable, Sendable {
    enum Source: Sendable { case manual, forecast }
    let temperatureCelsius: Double
    let source: Source
    let city: String?
    let timeZoneIdentifier: String?
}

@MainActor @Observable
final class WeatherModel {
    var query = ""
    var manualTemperature = ""
    var useManualTemperature = false
    private(set) var cities: [WeatherCity] = []
    private(set) var city: WeatherCity?
    private(set) var forecast: CityForecast?
    private(set) var busy = false
    private(set) var message: String?
    private let service: any CityWeatherService
    private var revision = UUID()

    init(service: any CityWeatherService) { self.service = service }

    func context(now: Date = Date()) -> OutfitWeatherContext? {
        let temperature: Double
        let source: OutfitWeatherContext.Source
        if useManualTemperature {
            guard let value = Double(manualTemperature.replacingOccurrences(of: ",", with: ".")),
                  value.isFinite, (-80...60).contains(value) else { return nil }
            temperature = value; source = .manual
        } else {
            guard let forecast, now.timeIntervalSince(forecast.updatedAt) >= 0,
                  now.timeIntervalSince(forecast.updatedAt) < 3600,
                  forecast.validAt >= now else { return nil }
            temperature = forecast.celsius; source = .forecast
        }
        return OutfitWeatherContext(temperatureCelsius: temperature, source: source,
                                    city: city?.name, timeZoneIdentifier: city?.timeZone.identifier)
    }

    func search() async {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !busy else { return }
        let token = begin()
        do {
            let results = try await service.cities(named: value)
            guard revision == token else { return }
            cities = results
            message = results.isEmpty ? "weather.noCities" : nil
        } catch { if revision == token { message = "weather.cityError" } }
        if revision == token { busy = false }
    }

    func locate() async {
        guard !busy else { return }
        let token = begin()
        do {
            let result = try await service.cityAtCurrentLocation()
            guard revision == token else { return }
            busy = false
            await select(result)
        } catch {
            if revision == token { busy = false; message = "weather.locationError" }
        }
    }

    func select(_ selected: WeatherCity) async {
        let token = begin()
        city = selected; forecast = nil; cities = []
        do {
            let result = try await service.forecast(for: selected)
            guard revision == token else { return }
            guard result.celsius.isFinite, (-80...60).contains(result.celsius) else { throw CityWeatherError.unavailable }
            forecast = result
        } catch { if revision == token { message = "weather.forecastError" } }
        if revision == token { busy = false }
    }

    func clear() {
        revision = UUID()
        service.cancelLocationRequest()
        city = nil; forecast = nil; cities = []; query = ""
        manualTemperature = ""; useManualTemperature = false; message = nil; busy = false
    }

    private func begin() -> UUID {
        revision = UUID(); busy = true; message = nil
        return revision
    }
}
