# T042 — city and weather

The native screen uses Apple geocoding for explicit city selection and an optional,
user-triggered approximate Core Location lookup. Forecasts use the authenticated
application gateway and free MET Norway Locationforecast, not WeatherKit. No
WeatherKit entitlement or Apple weather subscription is needed. No Always access,
background tracking, coordinate persistence or coordinate logging is added.

## Data path

`APIClient.forecast` sends coordinates rounded to two decimals in the body of
`POST /v1/weather`, with the current account session. Coordinates do not appear in
ordinary access-log URLs. The server handler authenticates before provider access,
accepts only latitude/longitude, and rejects oversized or malformed requests.
`backend/weather/met.mjs` sends no account identifier or client IP to MET, coalesces
nearby requests, bounds its cache and request rate, and honors Expires,
Last-Modified and Retry-After. Provider failures do not return expired cache data.

The native screen shows MET Norway and CC BY 4.0 links. Model issuance time is
preserved, never replaced by fetch time. Context accepts a model issued within
12 hours only for a forecast valid in the next two hours; it stops using that
forecast after its valid time. Times display in the selected city's time zone.
Manual signed Celsius input, including decimal commas, works without network,
login-dependent weather, city or location permission and overrides forecasts.
Leaving Today clears state and rejects late lookup results.

## Evidence and remaining integration

- The shared JavaScript harness passes 42 tests, including six provider/route
  regressions for authentication, owner injection, privacy, cache validation,
  throttling, request coalescing and malformed/stale/oversized data.
- A separate real MET request from the VPS returned a valid forecast. This proves
  provider availability, not the complete app path.
- Swift regression coverage includes the coarse authenticated request, fixed
  attribution, actual issuance timestamp, manual/offline fallback and late results.
  The updated native Debug build-for-testing passed. Runtime simulator execution
  remains pending.
- The route is mounted in the integrated gateway and configured in its entry point.
  Twelve targeted HTTP/provider tests pass, including revoked-session and deleted-account
  rejection before upstream access. Deployment and end-to-end native weather remain unverified.
- Outfit generation must still receive optional weather context and continue with
  nil after denied location or unavailable forecast. This remains incomplete.
- Device acceptance remains: Allow Once/While Using/approximate/denied location,
  disabled services, airplane mode, lookup timeout, ambiguous city names,
  different time zones, PL/EN, VoiceOver and maximum Dynamic Type.

Provider terms: https://docs.api.met.no/doc/TermsOfService.html
Integration guidance: https://docs.api.met.no/doc/locationforecast/HowTO
