# T013 — Native authentication and remaining service boundary

## Status

Implemented: native Apple authorization, email code UI, async gateway client,
device-only Keychain session storage, refresh coalescing, explicit Apple linking
confirmation, account isolation checks and localized error/retry states.

**T013 is not complete.** There is no provisioned authentication service, Apple
configuration, SMTP access, macOS toolchain or physical iPhone in this sandbox.
The new client describes an application gateway contract; that gateway is
**not implemented or deployed** in this repository. No successful sign-in,
private relay delivery, server-side linking policy or device test is claimed.
`AppDependencies.live()` uses `UnconfiguredAuthenticationService`; the existing
environment endpoint lock remains intact. No accounts or external services were
changed, and no dependencies were added.

A direct call to the proposed Supabase Auth API cannot be substituted for this
gateway: its identity linking policy must first be checked against SPEC's ban on
merging by email. Client-side confirmation alone cannot enforce that policy.
If the selected hosted auth cannot enforce it, T007's provider decision needs
revision or an identity broker that owns provider-subject mappings and never
passes untrusted email matches through to an auto-linking provider.

## Client behavior

- Email is passwordless: request a code, switch to Mail, return to the app and
  enter the code. No token-bearing deep links or URL schemes are accepted.
  An interrupted attempt can be restarted; codes and challenge IDs are not
  persisted. Server expiry, one-use verification and throttling are mandatory.
- Apple uses AuthenticationServices, 256-bit secure random nonce, SHA-256 nonce
  in the authorization request and one-use state correlation. Missing email on
  repeat authorization and private relay addresses do not affect client logic.
  Cancelling authorization leaves the current account unchanged.
- Linking Apple is available only while signed in and after a confirmation
  dialog followed by new Apple authorization. The request uses a separate
  authenticated endpoint. A response with a different user UUID is rejected.
  Email identity linking and merging existing accounts are not offered.
- The session is encoded only in Keychain, scoped to the bundle ID, with
  `WhenUnlockedThisDeviceOnly`. Refresh begins within 60 seconds of expiry,
  including foreground activation; concurrent callers share one refresh task.
  Permanent expiry clears credentials and returns to login. Transient failures
  preserve credentials for retry. There is no retry of an ambiguous auth write.
- API requests obtain a current token from the model. A 401 invalidates only
  the session whose token was rejected; mutations are never replayed implicitly.
- Sign-out removes the local session before attempting server revocation.
  Late login/refresh results cannot restore it. A Keychain deletion failure
  retains the visible session so the user can retry. Offline revocation failure
  is disclosed; remote revocation is not guaranteed or queued by this change.
- The authenticated view is keyed by server user UUID and removed on logout.
  Persistent wardrobe/widget caches do not exist here; their future stores must
  participate in account cleanup before production activation.
- Raw provider errors, tokens, email addresses and Apple credentials are never
  logged or displayed as diagnostic messages.

## Gateway v1 wire contract (implementation required)

All paths below are relative to the configured gateway base URL, **not** a
Supabase project URL. HTTPS, JSON POST body, 30-second client timeout. Key names
are case-sensitive. No admin secret or public API key is needed by this gateway
client. Bearer credentials are sent only to the identity-link endpoint.

| Path | Request | Success (200) |
| --- | --- | --- |
| `/auth/v1/email/start` | `{ "email": string }` | `{ "challengeID": UUID }` |
| `/auth/v1/email/verify` | `{ "challengeID": UUID, "code": string }` | Session |
| `/auth/v1/apple` | `{ "identityToken": string, "nonce": string }` | Session |
| `/auth/v1/identities/apple` | Apple body; `Authorization: Bearer <current access token>` | Session with unchanged userID |
| `/auth/v1/refresh` | `{ "refreshToken": string }` | Rotated Session with unchanged userID |
| `/auth/v1/logout` | `{ "refreshToken": string }` | `{}` |

Session: `{ "userID": UUID, "accessToken": nonempty string,
"refreshToken": nonempty string, "expiresAt": number }`; expiresAt is seconds
since Unix epoch and must be in the future. Access and refresh tokens must not
contain whitespace. Session tokens must be recognized by the T009 resource API
and bind its authenticated subject to the same user UUID.

Errors: non-2xx with `{ "error": { "code": string, "message": string,
"request_id": UUID } }`, matching T009's error envelope. 401 means invalid or
expired authentication; 409 means identity already owned by another account;
429 is throttled. Error bodies must not expose whether an email exists. The
client displays generic localized messages, never the raw server message.

Mandatory server invariants before enabling the client:

1. Validate Apple signature using trusted rotating keys, issuer, configured
   audience per app environment, expiry and SHA-256(raw nonce). Reject reused
   proofs. Identity keys are `(issuer, subject)` with a unique constraint;
   email, including relay email, is contact metadata only.
2. Email verification proves control of a normalized email identity through a
   short-lived, one-use challenge. Store only a protected verifier, limit
   attempts, throttle sending, prevent enumeration and bind codes to challenges.
   Never attach a new provider identity to an existing account by email match.
3. Linking requires both a recent session and fresh Apple proof. Atomically
   attach only an unowned identity; reject ownership by another user without
   moving data. Repeated confirmed linking to the same account is idempotent.
   A stale session requires reauthentication and a fresh confirmation.
4. Refresh tokens rotate/revoke server-side, deleted accounts cannot refresh,
   and ambiguous timeout/retry cannot create additional users or silently merge
   identities. Define a bounded refresh rotation recovery policy on the server.
5. Direct provider endpoints must not bypass the no-auto-link invariant.
   Database RLS alone does not enforce an identity provider's linking policy.

## Activation and acceptance procedure

1. Implement and review the gateway against the contract above; test collision
   and concurrency cases on an isolated backend. Confirm provider policy from
   current official documentation with network access. This was not possible
   in the sandbox; no claim about current hosted-provider capabilities is made.
2. Provision separate approved environment URLs and configure real SMTP,
   email code templates, rate limits, Apple audience and Sign in with Apple for
   each bundle ID. Refresh provisioning profiles for the checked-in entitlement.
   Configure Apple's relay sender requirements and verify delivery with a real
   relay mailbox. Keep signing material and credentials outside the repository.
3. Update the existing T006 endpoint guard with approved environment allowlists
   and tests, then wire `AppDependencies.configured(baseURL:authentication:
   transport:publicAPIKey:)` from validated configuration. AuthenticationClient
   uses the gateway URL; the resource API URL may be a different approved host.
   Do not weaken the current endpoint guard merely to demonstrate the UI.
4. Run the existing macOS CI matrix (Debug/Staging/Release); require successful
   compile and XCTest results including AuthenticationTests. Use the existing
   shared MojaSzafa scheme and retain xcresult artifacts. Linux harness checks
   verify structure and configuration, not Swift compilation or device behavior.
5. On a signed physical iPhone: email code sign-in after switching to Mail,
   wrong/expired/reused code, resend and cancellation; Apple first authorization
   with Hide My Email, repeat login with no email field, cancellation and revoked
   authorization; force-quit/reopen, expiry/refresh, offline retry and logout.
6. Use two synthetic accounts: same email across providers must not merge or
   expose either wardrobe. Cancel linking; confirm linking after recent login;
   try an Apple identity already owned by the other account, concurrent linking,
   stale session and forged/replayed Apple proofs. Verify server user UUIDs,
   identity ownership and RLS, not merely screen messages.
7. Record OS/device/build, environment, test date and pass/fail results without
   tokens or personal data. Both original T013 acceptance criteria remain
   **needs verification** until gateway implementation and device evidence exist.
