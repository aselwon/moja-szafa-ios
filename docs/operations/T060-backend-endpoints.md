# T060 backend endpoint manifest

`Configuration/BackendEndpoints.json` is the source of truth for the public
gateway origin assigned to each app environment: `dev`, `staging`, and `prod`.
Each value must be a distinct canonical HTTPS origin with no path, port,
credentials, query, or fragment. `scripts/validate-backend-endpoint.py` checks
that manifest and requires both `BACKEND_BASE_URL` and the built Info.plist value
to match the selected environment exactly. `scripts/check-environments.mjs`
also exercises invalid and cross-environment overrides before compilation.

All three manifest entries are currently empty. The corresponding xcconfig
values remain empty, and the live app/auth composition is intentionally
unconfigured. The manifest is a configuration prerequisite, not evidence that
any backend is deployed or accepted. Do not fill an entry until its separate
environment has a deployed public gateway and owner-approved endpoint evidence.

The temporary Cloudflare feature preview is not an app endpoint: its proxy
requires a private `X-Szafa-Preview-Key` unavailable to the native app. Do not
put that key into a build setting, plist, source tree, or client request. The
staging Neon branch is separate from the feature database; the approved database
bootstrap/migration review and a safe staging auth/transport deployment remain
pending. No environment is enabled by this change.
