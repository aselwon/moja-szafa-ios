# T060 staging gateway status

Current evidence as of 2026-11-06:

- Stable Cloudflare route: `https://szafa-staging.kredkuj.pl`. It is live; `/health` returned HTTP 200 and unauthenticated sync returned HTTP 401.
- `Configuration/BackendEndpoints.json` and `Configuration/Staging.xcconfig` point to this same staging host.
- The gateway currently runs source `7b04e3af3fb6a856e220765986ae5bb69bfe11e9`, including the managed-auth cookie fix and deployed image/export retention functions. The runtime uses a dedicated restricted database role. The staging database has 32 migration versions (001–032) with repository-matching checksums.
- A real OTP flow through the gateway succeeded using a non-personal test mailbox, and the profile was provisioned automatically. Staging smoke flows verified listing three garments and syncing, uploading and reading back JPEG/PNG photos with EXIF absent, exporting a 42,496-byte JSON package with photos and no session token, and the account-deletion API path.
- The separate AI worker is installed but inactive and disabled. AI/image processing remain disabled, the global/user limits remain 10/4, and no provider call is claimed.

These results verify gateway/API behavior on staging. The complete native app login-to-wardrobe flow has not yet been verified. PR #136 is merged at `9d37e2f45649829b73b25b254229c4f6b9434a0c`; its performance-related backend update is not yet deployed. No app performance conclusion is claimed from the gateway smoke measurements.

Historical note: the earlier temporary quick-tunnel endpoint has expired and is superseded by the stable hostname above. Do not use the former address.
