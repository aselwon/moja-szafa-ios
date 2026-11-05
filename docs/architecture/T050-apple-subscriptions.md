# T050 — Apple subscription verification

This feature adds a server-owned verification and entitlement ledger for
auto-renewable subscriptions. The Apple adapter is unavailable by default;
client state or a decoded but unsigned transaction never grants access. No
production offer, live merchant setup, or App Store review is claimed here.

## Configuration and Apple setup

The gateway needs all of the following non-secret environment settings before
it creates the verifier:

- `SUBSCRIPTIONS_ENVIRONMENT`: `sandbox` or `production`.
- `SUBSCRIPTIONS_BUNDLE_ID`: the app bundle identifier registered with Apple.
- `SUBSCRIPTIONS_MONTHLY_PRODUCT_ID` and `SUBSCRIPTIONS_YEARLY_PRODUCT_ID`:
  distinct product IDs configured in App Store Connect.
- `SUBSCRIPTIONS_APP_APPLE_ID`: the numeric app ID; required for production,
  optional in sandbox.

When every setting is absent, subscription routes return unavailable. A partial
or invalid configuration fails gateway startup. Operators must first create and
configure the app and subscription products in App Store Connect, set up the
App Store Server Notifications endpoint, and deploy the matching environment
and identifiers. Product prices are read from StoreKit by the app; this backend
does not set prices or infer a purchasable offer.

The gateway pins Apple Root CA G3 by SHA-256 and uses the pinned
`@apple/app-store-server-library` 3.1.0. Runtime verification requires online
certificate revocation checks and the configured Apple environment and bundle
ID. Xcode/local-testing verification modes are rejected. A network or retryable
Apple verification failure returns a retryable service error; provider details,
certificate data and signed payloads are not returned to clients.

## Routes and trust boundary

All account routes require the existing managed-session bearer token and
revalidate that session against the database:

- `GET /v1/subscriptions/catalog` returns the configured product identifiers
  and environment. It also preflights the database subscription schema and
  narrow gateway role, so environment variables alone do not enable purchases.
- `GET /v1/subscriptions/status` returns the caller's current entitlement
  projection.
- `POST /v1/subscriptions/transactions` accepts exactly
  `{ "signedTransaction": "<JWS>" }`. The gateway verifies the JWS, checks the
  transaction's bundle, environment, product and account token, then persists
  the normalized event.
- `POST /v1/subscriptions/apple-notifications` accepts exactly
  `{ "signedPayload": "<JWS>" }`. Apple calls this route without a user session;
  the signed notification and its nested transaction and renewal data must
  verify before any write. Apple `TEST` notifications are acknowledged without
  a ledger write. Storage errors remain retryable to Apple.

Requests reject unknown fields and oversized JSON. The verifier accepts only
the configured monthly/yearly products, validates transaction and renewal
claims, and binds `appAccountToken` to the authenticated owner for client
transactions. Webhook claims must match the configured bundle and environment.
The adapter stores normalized transaction/renewal fields and a SHA-256 digest
of each signed payload for deduplication; it does not persist raw JWS payloads.

The existing gateway contract loader only accepts standalone OpenAPI files whose
operations are `POST /rest/v1/rpc/api_v1_*`. These subscription endpoints are
direct `/v1/` HTTP routes, so a future contract needs an explicit convention or
a deliberate loader extension; no OpenAPI contract is added by this change.

## Ledger and access state

Migration 026 stores environment-scoped chains, transactions and receipt
digests in `api_private`; the tables and write/read functions are not exposed to
client roles. The verified gateway role records events through a narrow SQL
function. Unique environment/event and environment/transaction keys deduplicate
Apple retries, while owner and original-transaction checks reject account
rebinding. Database locking serializes writes and account deletion. Deleted or
deleting accounts are acknowledged without recreating an identity.

Entitlement state is recomputed from the newest transaction and verified
renewal data. Expiry and grace-period checks use the database clock, so access
expires without waiting for another notification. Refund/revocation and
upgrade claims remove access; a newer verified `REFUND_REVERSED` event can
clear a prior revocation. Sandbox and production histories remain separate.
The existing export snapshot includes normalized subscription history, and
account deletion removes the owner-scoped rows through their foreign keys.

## AI and validation boundaries

Subscription status does not change AI policy, admission, or quotas. AI remains
disabled by default; the existing policy defaults remain 10 units per user and
100 globally per day, with outfit generation reserving its existing two-call
budget. No Plus-specific quota or paid AI allowance is introduced.

The full SQL migration, concurrency and recovery suite passed on disposable
PostgreSQL 15.19. Focused lifecycle, deduplication, owner/environment isolation,
export, billing-retry and refund-reversal cases passed, as did one actual
least-privilege `GatewayStore` PostgreSQL integration test. The Node verifier
and HTTP suite uses synthetic transactions and Apple certificate fixtures.
Native purchase wiring, live Apple merchant validation and App Store
notification delivery remain pending. No production product IDs, prices,
merchant records or live transactions have been validated.
