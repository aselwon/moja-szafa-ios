# T049: native StoreKit purchase mechanics

The native adapter loads a monthly and yearly auto-renewable subscription from
one StoreKit group. It rejects missing products, wrong periods and mixed groups.
Names and displayed prices come from StoreKit. No production product identifier,
price, trial or entitlement limit is invented by this implementation.

`SubscriptionConfiguration` reads optional `StoreKitMonthlyProductID` and
`StoreKitYearlyProductID` bundle values. Both remain absent by default. The Profile
purchase screen therefore reports that purchases are unavailable. Even with IDs
supplied, the app performs an asynchronous backend-receiver preflight before it
starts a purchase or calls restore. An unconfigured receiver prevents both, so
the app cannot charge for an entitlement the backend cannot honor. T050 supplies the authoritative receiver; T051 supplies the full paywall,
legal disclosures and entitlement-aware placement after the offer is configured.

The StoreKit adapter handles verified results, pending purchases and cancellation.
It attaches the authenticated app account UUID through `appAccountToken` and
rejects receipts belonging to another account. Signed receipts stay in memory;
they are never logged, put in URLs or stored in an application-owned journal.
StoreKit itself retains unfinished transactions for redelivery.

The service starts a transaction-update listener, retries unfinished transactions,
and offers explicit `AppStore.sync()` restore. It finishes a transaction only
after the server acknowledges the same transaction ID. An interrupted server
request leaves the transaction unfinished. Logout/account deletion stops the
listener and fences in-flight acknowledgements. Identical in-flight receipts are
coalesced; a later refund/revocation receipt with the same transaction ID is not
permanently suppressed. No local `isPlus` value or device clock grants AI access.

## Local verification

`MojaSzafaTests/TestProducts.storekit` contains two clearly synthetic test-only
products and sample prices. Dedicated `MojaSzafaStoreKit`,
`MojaSzafaStoreKitStaging`, and `MojaSzafaStoreKitRelease` schemes inject the
fixture through their launch actions. Their test actions reference
`MojaSzafaStoreKit.xctestplan`, which selects the test target and disables
parallel test execution. StoreKit configuration is not a supported test-plan
option in the installed Xcode; the fixture path belongs to the scheme's
`StoreKitConfigurationFileReference`. The normal `MojaSzafa` and
`MojaSzafa-Staging` schemes and production configuration do not reference the
fixture. It is not an approved offer and is not uploaded to App Store Connect.
Apple supports local StoreKit configuration before App Store Connect setup:
[StoreKit testing setup](https://developer.apple.com/documentation/Xcode/setting-up-storekit-testing-in-xcode).

`SubscriptionTests` covers missing configuration, mixed groups, pending/cancelled
purchases, account separation, server acknowledgement, failed-network redelivery,
and logout fencing. `SubscriptionStoreKitTests` loads the real local StoreKit
session, requests localized products, purchases through the actual adapter,
checks SDK verification/account binding/current and unfinished transactions, and
finishes the transaction. It does not contact a live App Store merchant account.

The initial iOS 26.5 runtime fails StoreKit configuration mutation with
`SKInternalErrorDomain Code=3`, including under ad-hoc simulator signing. This is
a [documented Apple runtime issue](https://developer.apple.com/forums/thread/826971).
Use a compatible runtime for this integration test; do not turn that failure into
a skipped/passed purchase test. A fresh iOS 27.2 Release simulator
(`0209F467-2EA6-488F-86E2-30FF825F5492`) built successfully with CI's
unsigned/testability settings. CI now runs a separate provisioning test host
first: it loads the local fixture with `SKTestSession`, resets it, disables
dialogs, and confirms there are no transactions. It performs no purchase. That
test passed 1/1 (0.354 seconds); the next, separate process ran the actual local
purchase/verification/restore-scan test, which passed 1/1 (0.172 seconds). Both
used the Release app bundle `pl.mojaszafa.app` on the fresh simulator, with no
Apple account interaction. This validates the two-step flow on that simulator;
it does not establish that provisioning is necessary on every runtime or
simulator state. An earlier Release attempt on an existing simulator displayed
an Apple Account prompt and was stopped without credentials. The focused
subscription and authentication suites previously passed 23/23 on iOS 27.2.

On CI, a fresh simulator took about 89 seconds to launch the provisioning test
host, leaving less than half a second before the original 90-second command
limit expired. No assertion result was recorded. The provisioning command now
has a 300-second startup budget, matching the focused suite; the one-time
recovery remains limited to launch/timeouts before any test starts.

## Remaining external acceptance

Live monthly/yearly products in one App Store Connect group, approved prices and
trial terms, publisher account agreements, physical-device sandbox purchases and
server notification registration still need the publisher's Apple account and
offer decisions. Local fixture transactions are not proof of those external steps.
The unconfigured receiver intentionally remains unavailable until T050's server
verification is wired; client-side verification alone never unlocks Plus.
