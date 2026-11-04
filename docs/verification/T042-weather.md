# T042 — city and weather

Today now offers Apple geocoding (city/region/country with explicit result selection),
a user-triggered, approximate, one-shot Core Location request and the next hourly
WeatherKit forecast. The screen shows retrieval time and forecast time in the city's
IANA time zone, Apple attribution and a source link. It never requests Always access,
background location or temporary full accuracy. Coordinates are not persisted or logged.
Leaving Today clears the screen state; a late result cannot repopulate it.

Manual temperature accepts signed Celsius values, including a decimal comma. It
works without network, a city or location permission. An unavailable/expired forecast
produces no context, not a failure that prevents outfit ranking. Forecast context
expires after one hour or its forecast hour. Explicit manual input overrides weather.

## Verification still required

- Run the shared MojaSzafa scheme tests in macOS CI; this Linux sandbox has no Xcode
  or Apple SDK. WeatherTests cover manual selection without a location request,
  denied location, offline weather, manual validation, city time zones, stale data,
  city changes and results arriving after clearing the screen.
- Enable WeatherKit for each environment's App ID and regenerate provisioning profiles
  using the owner's Apple Developer access. The entitlement is checked in; no account
  configuration or paid API call was performed. Until provisioned, failure falls back
  to manual temperature and must not be reported as a verified live forecast.
- On an iPhone, verify no prompt at launch or city search; Allow Once, While Using,
  approximate location, denial, disabled location services, timeout, airplane mode,
  refresh and leaving the screen during lookup. Confirm no background location use.
- Search cities in different time zones and ambiguous names; verify chosen city,
  next forecast hour, retrieval timestamp and Apple attribution in light/dark mode.
  Check Polish/English, VoiceOver and maximum Dynamic Type.

## Existing integration boundary

The checkout's Today screen was a placeholder and there is no iOS AI suggestion
request flow to connect to. `WeatherModel.context(now:)` supplies optional typed
ranking input (manual/forecast provenance, Celsius, city and time zone); a future
suggestion caller must allow nil and must not require location permission. End-to-end
verification that suggestions continue after denial therefore remains blocked on that
flow (T030 dependency). This change does not invent an AI endpoint or claim that the
end-to-end acceptance criterion is complete. No weather data or precise coordinates
are sent to AI by this change.
