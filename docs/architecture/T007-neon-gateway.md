# T007 — Neon staging gateway integration

This implementation makes the existing Swift API contract executable against
Managed Better Auth and PostgreSQL. It does not claim deployment, email delivery,
Apple sign-in, AI-provider execution, account-erasure completion or recovery SLA.

## Identity and native client contract

The gateway uses the provisioned branch's Managed Better Auth REST API. OTP codes
are generated, delivered, verified and consumed by that service. The gateway
stores only a short-lived UUID-to-email challenge mapping, attempt counters and
delivery-rate metadata. It stores no passwords, OTP verifiers or newly minted
authentication tokens. Challenge metadata expires after five minutes and is
purged after one hour when a new challenge starts.

The existing Swift `AuthSession` DTO stays unchanged:

```json
{
  "userID": "provider-user-uuid",
  "accessToken": "opaque-provider-signed-session-cookie-value",
  "refreshToken": "same-provider-signed-session-cookie-value",
  "expiresAt": 1793786400
}
```

The token fields are opaque. They contain only the provider-issued
`__Secure-neonauth.session_token` cookie value, not a JWT, invented refresh token
or complete Cookie header. Native clients keep these values in their existing
Keychain store. Resource requests use `Authorization: Bearer <accessToken>`.

| Gateway route | JSON body | Response |
| --- | --- | --- |
| `POST /auth/v1/email/start` | `email` | `challengeID` UUID |
| `POST /auth/v1/email/verify` | `challengeID`, `code` | AuthSession |
| `POST /auth/v1/refresh` | `refreshToken` | AuthSession after managed session renewal |
| `POST /auth/v1/logout` | `refreshToken` | `{}` after managed sign-out |

Renewal follows the managed provider's session policy. The gateway does **not**
promise a separately rotating refresh token. Once the managed session expires,
the user must authenticate again. Apple and identity-link routes return an
explicit not-configured error until real provider credentials and collision/
linking-policy evidence exist; they never synthesize an identity.

Every protected request sends **only** the managed session-token cookie to the
fixed configured Auth URL's `/get-session?disableCookieCache=true`. No cached
`session_data` cookie is forwarded. Verified email, a non-banned user, matching
session/user UUIDs, a future expiry and no impersonation are mandatory. Network
errors fail closed. Redirects, arbitrary auth origins, oversized tokens and
header-injection characters are rejected. Logs never contain auth bodies,
cookies, connection strings or raw provider errors.

Managed JWTs have a 15-minute lifetime and user claims without a session ID.
JWKS verification alone therefore cannot prove immediate session revocation.
This gateway deliberately uses live managed sessions and additionally rechecks
the same session and deletion state inside each database transaction. It does
not accept a JWT as a substitute for the signed session cookie.

## PostgreSQL boundary

Apply `backend/deploy/neon-bootstrap.sql` as the migration owner **before**
`backend/migrate.sh`. Managed Better Auth must already have created `neon_auth`.
The provider bootstrap is separate from versioned app migrations and is
idempotent; it never replaces the production provider with the CI auth shim.

`auth.users` is a compatibility table because app tables require a foreign-key
target. Its UUID primary key references `neon_auth."user"(id)` with deletion
cascade. There is no email-based linking or copied credential material. The
gateway creates the compatible identity/profile only after a verified, live
managed session and a check for an existing deletion job. Deleted profiles and
deletion ledgers prevent automatic resurrection.

A BEFORE DELETE guard on the compatibility identity also protects against
provider-native account deletion bypassing app cleanup. The separate trusted
deletion worker must first complete independent deletion-journal recording and
private-byte erasure, then call `gateway_private.approve_identity_erasure` with
the current owner, deletion-job UUID and fencing token, and finally remove the
managed identity. Approval requires a live running lease, expires within five
minutes and is consumed by deletion. The public gateway cannot grant approval.
Until the worker adapters exist, direct managed deletion fails closed rather
than orphaning private photos or losing deletion evidence.

Provision a dedicated LOGIN role belonging only to `szafa_gateway`, with its
password delivered outside Git. This role cannot read provider users/sessions,
compatibility identities or challenge rows. Narrow definer functions validate
the managed session, create only its corresponding profile and expose bounded
resource operations. The migration owner retains its existing BYPASSRLS role;
the public gateway refuses to start with an owner/BYPASSRLS/superuser identity.

For `/rest/v1/rpc/<operation>`, operation names come only from the checked-in
OpenAPI contract. JSON values are SQL parameters. One checked-out connection
holds the transaction, server-derived owner and session context, then runs as
`authenticated`. COMMIT/ROLLBACK clears the local context before pool reuse.
Existing SQL validation, ownership checks and durable mutation replay remain.

Image and export handlers are mounted on the same origin with the existing
private-file adapters. Their narrow SQL bridge overwrites any payload owner
with the validated principal and disallows administrative cleanup actions.
Cleanup/worker identities remain separate from the public gateway.

## Deployment configuration

Install the pinned driver with `npm ci --prefix backend/gateway --ignore-scripts`.
Run `node backend/gateway/main.mjs` under a supervisor behind the authorized TLS
reverse proxy. It binds only to `127.0.0.1`; `/health` contains no private data.
Python and the existing `backend/images/requirements.txt` decoder dependency
must be installed for image normalization. Do not expose private volumes as
static files. The HTTP service has bounded bodies, connection timeouts,
concurrency and email-start rate limits; preserve equivalent limits in the proxy.

Required environment variable names (values are never checked in):

- `DATABASE_URL`: dedicated gateway LOGIN, TLS `sslmode=verify-full`.
- `NEON_AUTH_BASE_URL`: fixed branch Managed Auth URL ending in `/auth`.
- `PRIVATE_IMAGE_DIRECTORY`: absolute durable private image directory.
- `EXPORT_DIRECTORY`: absolute private export spool.
- `IMAGE_SIGNING_KEY`: 32-byte persistent capability key encoded as 64 hex digits.
- `PORT`: optional loopback listener port, default 8080.

For initial email-only staging, disable unintended OAuth providers and require
verified email. Provider-native endpoints must not bypass the no-auto-link
requirement before any additional provider is enabled. Shared SMTP is suitable
for development; production email configuration is a separate external gate.
No paid AI calls are made by this service.

## Verification and remaining gates

`backend/tests/gateway.test.mjs` exercises actual local HTTP against synthetic
managed-provider responses: exact cookie forwarding, unchanged Swift DTO,
renewal, wrong-code errors, unverified users, logout and immediate denial,
tombstones, untrusted origins, injection and size limits. It sends no real email.

`GATEWAY_PG_TESTS=1 node --test backend/gateway/postgres.test.mjs` uses configured
libpq host/user parameters and creates only its own uniquely named disposable
database. It installs a **test-only** provider-table fixture, reapplies the real
bootstrap, runs every app migration, and exercises HTTP + real SQL writes,
replay, cross-owner isolation, private-table grants, session-revocation races,
tombstones, metadata rate limits and managed-user deletion cascade. Never point
this test at a production/shared provider database. CI executes both suites.

These tests establish application boundaries; they do not establish delivery of
a real OTP, a successful hosted managed login or actual deployment. Record those
separately after authorization. Account-deletion workers still require working
managed-identity removal, independent backup-deletion journal and storage cleanup
adapters; the gateway does not falsely acknowledge erasure. AI runtime adapters,
backup scheduling and representative restore measurements remain separate work.

Official API sources checked on 2026-11-04:

- [Managed Email OTP](https://neon.com/docs/auth/guides/plugins/email-otp)
- [Managed JWT semantics](https://neon.com/docs/auth/guides/plugins/jwt)
- [Managed OpenAPI endpoint](https://neon.com/docs/auth/guides/plugins/openapi)
- [Managed authentication flow](https://neon.com/docs/auth/authentication-flow)
- [node-postgres transactions](https://node-postgres.com/features/transactions)

The provisioned branch's read-only `/open-api/generate-schema` was inspected for
the actual send-OTP, sign-in, get-session and sign-out request/response shapes.
