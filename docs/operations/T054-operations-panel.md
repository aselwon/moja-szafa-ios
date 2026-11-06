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

`OPS_TOKEN_TYPE` optionally selects the token profile. It defaults to `access_token`, which requires a signed `at+jwt` token and `jti`. Set it to `oidc_id_token` only for a dedicated confidential OIDC proxy client; that profile requires a signed `JWT` ID token with a nonce, recent `auth_time`, and MFA in `amr`, and checks audience/authorized-party consistency. The service never falls back between profiles and the request cannot choose the profile. The proxy must perform the OIDC authorization flow and validate state, nonce, and PKCE, then replace any caller-supplied `Authorization` header with the validated ID token. This profile is opt-in and has not been deployed or tested against a live identity provider.

`OPS_ISSUER`, the JWKS URL, and the public origin must use HTTPS. The JWKS URL must share the issuer's origin, and the public origin must be a bare origin without a path, query, or fragment. The configured issuer, audience, JWKS endpoint, and public origin are fixed by server configuration; a token cannot choose them.

Both token profiles accept only RS256 or ES256 signatures verified with the configured remote JWKS. They require the exact issuer and audience, a bounded token lifetime and maximum age of 15 minutes, a recent `auth_time` (no more than 15 minutes old), and `amr` containing `mfa`. Both require `sub`; the access-token profile also requires `jti`, while the opt-in ID-token profile requires a nonempty `nonce` and validates `azp` when present or when the audience is multi-valued. Identity fields such as role in a token are ignored: the database registry is authoritative.

## Database roles and operator registry

Migration 027 creates a private `ops_private` schema, an operator registry, immutable audit storage, and a control row that captures the existing AI policy ceilings. The migration creates no login role or operator identity.

Migration 027 is present in the deployed schema. Run `backend/operations/bootstrap.sql` as the schema owner to create the `szafa_ops` execution role as `NOLOGIN`, `NOINHERIT`, `NOSUPERUSER`, and `NOBYPASSRLS`, granting only schema usage and execution of the narrow operations command function. Provision a separate least-privileged `NOINHERIT LOGIN` database role as a member of `szafa_ops` through the protected deployment channel. Never reuse the consumer gateway login, owner, or `service_role` credentials. The runtime checks that its database role is not privileged and belongs to `szafa_ops` only.

Before opening its loopback listener, startup verifies that `current_user` is the actual login identity, that the login is `NOINHERIT` and has no elevated role attributes, and that its only group membership is `szafa_ops`. It also refuses a login that owns the current database or protected schemas, or a `szafa_ops` role with additional inherited memberships. A failed check closes the pool and leaves the service unavailable.

Operator rows must be provisioned separately after the SSO identity exists, using its exact issuer and subject and an explicit `viewer`, `support`, or `admin` role. Rows are disabled by default. This service does not create identity credentials or app users.

## Available operations and privacy

All requests require the signed bearer token. The UI and command endpoint enforce the configured origin, bounded request size, rate limits, and an allowlist of commands. There is no impersonation command.

The summary provides service health, aggregate job/image/deletion/support counts, current AI policy values, and aggregate AI call/token data for cost estimates. It does not return account identifiers or profiles, wardrobe contents, photos, authentication tokens, or identity-provider credentials. The estimate is not an invoice.

Support access is explicit: `support` and `admin` roles may list, read, or update a support request by ID. A support read returns the request's subject and message text, bounded to the documented display limits; it does not provide access to wardrobe records or photos. `viewer` may read the summary only. `admin` may also list audit summaries and update AI policy.

Admin policy updates use compare-and-swap version checks and execute with their audit record in the same database transaction. Audit rows are immutable, and duplicate request IDs cannot be reused for different commands. At migration time, the operations control row captures the currently configured global and per-user AI policy limits. The panel rejects any requested limit above those captured ceilings; increasing a ceiling requires a separately reviewed database change. Enabling image AI while global AI is disabled is also rejected.

## Validation and remaining work

Local validation includes five authentication and HTTP tests, the full operations SQL policy/audit suite, and one HTTP-to-PostgreSQL integration test after the startup role guard was added. The focused tests cover both the default access-token profile and the opt-in OIDC ID-token profile, recent MFA requirements, role enforcement, audit atomicity/immutability, optimistic versioning, idempotency, startup rejection of unsafe database roles, and request boundary checks. The repository harness passed 93/93 tests with the current operations auth changes.

A synthetic browser smoke check loaded the panel against a loopback mock API and displayed a synthetic support request in both the list and detail view. This checks the browser presentation and role-gated list/detail path only; it does not authenticate through a real SSO proxy or validate an actual operator identity.

Live operations access remains unvalidated. Completion requires a configured MFA-capable SSO proxy that injects the verified bearer token, separately provisioned operator identities and least-privileged database login, and a live end-to-end operator flow. Migration 027 is deployed, but no deployed IdP or proxy is configured. No AI policy or quota was modified or deployed by this work. T054 must not be marked complete on the strength of local tests alone.
