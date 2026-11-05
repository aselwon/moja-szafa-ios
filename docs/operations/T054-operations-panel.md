# T054 — restricted operations panel (partial)

## Current state

The local operations service, database command boundary, and operator access checks are implemented. T054 is not complete or ready for live operator use: no MFA-capable identity provider or reverse proxy has been configured or deployed, no operator identities or login credentials have been provisioned, and migration 027 has not been applied to a deployed database. The deployment remains unchanged.

The service listens on `127.0.0.1` only. It expects a trusted, MFA-capable SSO proxy to inject an `Authorization: Bearer ...` access token on each request. It does not implement an identity provider, login page, or consumer-account authentication. Do not expose the loopback service directly to a network or treat this implementation as live-ready before a trusted proxy and operator registry are provisioned.

## Trust and configuration

The operations service is disabled unless all of these non-secret settings are supplied:

- `OPS_ISSUER`
- `OPS_AUDIENCE`
- `OPS_JWKS_URL`
- `OPS_PUBLIC_ORIGIN`
- `OPS_DATABASE_URL`

Optional settings are `OPS_PORT` (default `18082`) and `OPS_GATEWAY_HEALTH_URL`. The health URL, when supplied, must target `http://127.0.0.1:<port>/health`; it cannot point to a remote host. This document intentionally contains no setting values or credentials.

`OPS_ISSUER`, the JWKS URL, and the public origin must use HTTPS. The JWKS URL must share the issuer's origin, and the public origin must be a bare origin without a path, query, or fragment. The configured issuer, audience, JWKS endpoint, and public origin are fixed by server configuration; a token cannot choose them.

The verifier accepts only signed `at+jwt` access tokens using RS256 or ES256 and verifies them with the configured remote JWKS. It requires the exact issuer and audience, and the `sub`, `jti`, `iat`, `exp`, `amr`, and `auth_time` claims. The token lifetime and maximum age are 15 minutes, `auth_time` must be no more than 15 minutes old, and `amr` must include `mfa`. Identity fields such as role in a token are ignored: the database registry is authoritative.

## Database roles and operator registry

Migration 027 creates a private `ops_private` schema, an operator registry, immutable audit storage, and a control row that captures the existing AI policy ceilings. The migration creates no login role or operator identity.

After migration 027, run `backend/operations/bootstrap.sql` as the schema owner. It creates the `szafa_ops` execution role as `NOLOGIN`, `NOINHERIT`, `NOSUPERUSER`, and `NOBYPASSRLS`, granting only schema usage and execution of the narrow operations command function. Provision a separate least-privileged `NOINHERIT LOGIN` database role as a member of `szafa_ops` through the protected deployment channel. Never reuse the consumer gateway login, owner, or `service_role` credentials. The runtime checks that its database role is not privileged and belongs to `szafa_ops` only.

Operator rows must be provisioned separately after the SSO identity exists, using its exact issuer and subject and an explicit `viewer`, `support`, or `admin` role. Rows are disabled by default. This service does not create identity credentials or app users.

## Available operations and privacy

All requests require the signed bearer token. The UI and command endpoint enforce the configured origin, bounded request size, rate limits, and an allowlist of commands. There is no impersonation command.

The summary provides service health, aggregate job/image/deletion/support counts, current AI policy values, and aggregate AI call/token data for cost estimates. It does not return account identifiers or profiles, wardrobe contents, photos, authentication tokens, or identity-provider credentials. The estimate is not an invoice.

Support access is explicit: `support` and `admin` roles may list, read, or update a support request by ID. A support read returns the request's subject and message text, bounded to the documented display limits; it does not provide access to wardrobe records or photos. `viewer` may read the summary only. `admin` may also list audit summaries and update AI policy.

Admin policy updates use compare-and-swap version checks and execute with their audit record in the same database transaction. Audit rows are immutable, and duplicate request IDs cannot be reused for different commands. At migration time, the operations control row captures the currently configured global and per-user AI policy limits. The panel rejects any requested limit above those captured ceilings; increasing a ceiling requires a separately reviewed database change. Enabling image AI while global AI is disabled is also rejected.

## Validation and remaining work

The current local validation includes four authentication and HTTP tests, focused SQL policy/audit tests, and one HTTP-to-PostgreSQL integration test. The tests cover signed token and recent MFA requirements, role enforcement, audit atomicity/immutability, optimistic versioning, idempotency, and request boundary checks.

Live operations access remains unvalidated. Completion requires a configured MFA-capable SSO proxy that injects the verified bearer token, separately provisioned operator identities and least-privileged database login, and an approved migration 027 deployment. No deployed IdP or proxy is configured, migration 027 remains unapplied, and T054 must not be marked complete on the strength of local tests alone.
