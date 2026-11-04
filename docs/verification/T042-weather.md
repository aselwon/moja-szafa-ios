# T042 — city and weather

## Free-provider integration in progress

`backend/weather/met.mjs` implements a server-side MET Norway Locationforecast
adapter. It rounds coordinates to two decimals, sends no account identifiers or
client IP to the provider, coalesces nearby requests, bounds the cache and upstream
request rate, honors Expires/Last-Modified and Retry-After, and rejects stale or
malformed forecasts. Returned attribution includes MET Norway and CC BY 4.0.
The source model issuance timestamp is preserved; it is not replaced by fetch time.
Native context accepts a model issued within twelve hours only for a forecast
valid within the next two hours, and stops using it after its validity time.

Five provider regression tests run in the shared harness check (41 tests passed
locally on 2026-11-04). A separate real request from the VPS returned a valid
forecast. Neither result proves app integration: the authenticated gateway route,
native client replacement, visible MET attribution and outfit request wiring are
still pending. The native service below currently remains WeatherKit-backed.

Provider references: https://docs.api.met.no/doc/TermsOfService.html and
https://docs.api.met.no/doc/locationforecast/HowTO .

Today now offers Apple geocoding (city/region/country with explicit result selection),
a user-triggered, approximate, one-shot Core Location request and the next hourly
WeatherKit forecast. The screen shows retrieval time and forecast time in the city's
IANA time zone, Apple attribution and a source link. It never requests Always access,
background location or temporary full accuracy. Coordinates are not persisted or logged.
Leaving Today clears the screen state; a late result cannot repopulate it.

Manual temperature accepts signed Celsius values, including a decimal comma. It
works without network, a city or location permission. An unavailable/expired forecast
produces no context, not a failure that prevents outfit ranking. Forecast context
expires at its forecast hour or when the source model is too old. Explicit manual input overrides weather.

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
