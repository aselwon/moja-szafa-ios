import SwiftUI

struct TodayView: View {
    @State private var weather: WeatherModel

    init(repository: (any WeatherForecastRepository)? = nil) {
        _weather = State(initialValue: WeatherModel(service: AppleCityWeatherService(repository: repository)))
    }

    var body: some View {
        Form {
            Section {
                Text("weather.optional")
                TextField("weather.city", text: $weather.query)
                    .textContentType(.addressCity)
                Button("weather.search") { Task { await weather.search() } }
                    .disabled(weather.busy || weather.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("weather.locate", systemImage: "location") { Task { await weather.locate() } }
                    .disabled(weather.busy)
                ForEach(Array(weather.cities.enumerated()), id: \.offset) { _, city in
                    Button(city.name) { Task { await weather.select(city) } }
                        .disabled(weather.busy)
                }
                if weather.busy { ProgressView() }
                if let message = weather.message { Text(LocalizedStringKey(message)) }
            } header: { Text("weather.title") }
            if let city = weather.city {
                Section {
                    Text(city.name)
                    LabeledContent("weather.timeZone", value: city.timeZone.identifier)
                    if let forecast = weather.forecast {
                        Text(Measurement(value: forecast.celsius, unit: UnitTemperature.celsius), format: .measurement(width: .abbreviated, usage: .asProvided))
                        LabeledContent("weather.validAt", value: date(forecast.validAt, zone: city.timeZone))
                        LabeledContent("weather.updatedAt", value: date(forecast.updatedAt, zone: city.timeZone))
                        TimelineView(.periodic(from: .now, by: 60)) { timeline in
                            if !weather.useManualTemperature && weather.context(now: timeline.date) == nil {
                                Text("weather.stale")
                            }
                        }
                        Link(forecast.source, destination: forecast.attributionURL)
                        if let license = forecast.licenseURL {
                            Link("CC BY 4.0", destination: license)
                        }
                    }
                    Button("weather.refresh") { Task { await weather.select(city) } }.disabled(weather.busy)
                }
            }
            Section {
                Toggle("weather.manual", isOn: $weather.useManualTemperature)
                if weather.useManualTemperature {
                    TextField("weather.temperature", text: $weather.manualTemperature)
                    Text("weather.range")
                }
                Text("weather.fallback")
                Button("weather.clear") { weather.clear() }
            }
        }
        .navigationTitle("tab.today")
        .onDisappear { weather.clear() }
    }

    private func date(_ value: Date, zone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium; formatter.timeStyle = .short; formatter.timeZone = zone
        return formatter.string(from: value)
    }
}
