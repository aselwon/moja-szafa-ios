# T060 staging gateway deployment

The gateway is deployed as an isolated staging service from backend source
commit `7f867cd340f1849d4beb53802f87fe53454b4f87`. Its systemd unit is active
and enabled. Runtime configuration is supplied by a root-owned, mode-0600
environment file outside this repository; its contents are not part of this
deployment record.

The service uses a dedicated restricted staging database role and the app
migration ledger contains versions 001–026. Migrations 027 and 028 are not
deployed. AI remains disabled, with global and per-user limits unchanged at 10
and 4. No provider call was made or enabled.

At the recorded verification time, the public origin was
`https://varied-aging-fast-enough.trycloudflare.com`, a temporary Cloudflare
quick-tunnel hostname that can change after a tunnel restart. Its health route
returned HTTP 200. An unauthenticated sync request returned HTTP 401, and
malformed input returned HTTP 400. These checks show that the gateway is
reachable and rejects those requests; they do not verify a successful signed-in
session.

Positive authentication and native-app end-to-end behavior remain unverified.
This is staging evidence only and does not establish a stable production
origin, photo-storage acceptance, or production readiness.

## Endpoint update — 2026-11-05

After the staging quick-tunnel service was restarted, the currently configured
public origin is `https://frozen-clearing-seek-ancient.trycloudflare.com`.
The public `/health` route returned HTTP 200 at the time of this update; the
previous quick-tunnel hostname returned HTTP 530 and is no longer configured.
The hostname remains temporary and can change after another restart. The
checked-in staging allowlist and `Staging.xcconfig` use the current hostname.
This endpoint update does not verify signed-in authentication or native-app
end-to-end behavior.
