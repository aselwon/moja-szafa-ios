# T060 staging gateway deployment

The gateway is deployed as an isolated staging service from backend source
commit `9f4fe3897f9e038e61fbb648a885628f697a73f5` at 2026-11-05 21:27:30 UTC.
Its systemd unit is active and enabled. Runtime configuration is supplied by a
root-owned, mode-0600 environment file outside this repository; its contents
are not part of this deployment record. The deployment receipt recorded health
`ok`, unauthenticated recognition returning HTTP 401, no schema change, and no
services added.

The service uses a dedicated restricted staging database role. A read-only
ledger verification recorded exactly 32 migration versions (001–032) with
repository-matching checksums. The T029–T032 staging release package was
completed against merged source and its migration checksums were revalidated.
AI remains disabled, with global and per-user limits unchanged at 10 and 4. No
provider call was made or enabled.

The temporary public origin currently observed for the staging quick tunnel is
`https://frozen-clearing-seek-ancient.trycloudflare.com`; it can change after a
tunnel restart. PR #114, which updates the checked-in staging endpoint, is
pending. Earlier endpoint checks observed an unauthenticated sync request
returning HTTP 401 and malformed input returning HTTP 400. These checks show
reachability and rejection of those requests; they do not verify a successful
signed-in session.

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
