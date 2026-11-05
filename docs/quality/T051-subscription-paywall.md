# T051 — Subscription paywall and management

The Profile subscription screen shows the monthly and yearly products returned by
StoreKit. Product names and localized prices come directly from StoreKit. An
introductory offer is shown only when StoreKit reports an offer and the account is
eligible; its payment mode, price, period, and count use StoreKit values. The screen
discloses automatic renewal and provides a close action, restore, and Apple's
subscription management sheet.

The current plan section reads the authenticated `/v1/subscriptions/status`
response. It presents each server-reported product, status, period end, and grace
period end when available. Status remains unavailable when the server cannot be
reached. The screen does not grant access from local state; the server remains the
authority. Losing subscription access does not delete wardrobe data or prevent
export.

Purchases require both privacy and terms URLs from the app bundle. The client
accepts only HTTPS URLs without credentials, query strings, fragments, or
nonstandard ports. If either URL is absent or invalid, new purchases remain
disabled while restore remains available when the StoreKit service is
configured. Apple's management sheet remains available from the screen. The
current app configuration supplies neither these URLs nor production StoreKit
product IDs. With no product IDs, the service is not constructed; the screen
reports purchases unavailable and does not expose product purchase or restore
actions, while Apple subscription management remains available. Purchases are
unavailable by default. The exact Free/Plus limits, prices, and trial terms remain
owner decisions tracked by T048; this implementation invents none.

## Verification

On the dedicated iOS 27.2 simulator, the Debug `MojaSzafaStoreKit` scheme was built
with `CODE_SIGNING_ALLOWED=NO` and `ENABLE_TESTABILITY=YES`. A separate test-host
process provisioned the local StoreKit fixture and passed 1/1 setup test. The
focused API client, authentication, subscription, and local StoreKit purchase,
verification, and restore-scan tests then passed 42/42 with no skipped tests.

The StoreKit products are synthetic test fixtures. These results do not establish
live App Store merchant configuration, approved commercial terms, physical-device
purchases, or Apple server-notification setup. No real Apple account or purchase
was used.
