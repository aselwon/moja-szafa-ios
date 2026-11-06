# T056 security verification matrix

Status: **In Progress**. This record covers the deterministic security checks and
dependency/runtime evidence listed below. It does not claim full model robustness
or that the application is vulnerability-free.

## Exact-head CI evidence

[PR116 CI run](https://github.com/aselwon/moja-szafa-ios/actions/runs/42136026719)
completed successfully for head
`d122f9df1c9ef74b63c90c274dcff2ebf149fb3d`, based on main
`84bb2c62e0ab6e122fc27e046f2842b5265159ef`. The backend tree hash at the run
head and that audited main revision is identical:
`7110b7da07381485eede89629af2ceb3ef3dd2c8`.

The later [PR120 CI run](https://github.com/aselwon/moja-szafa-ios/actions/runs/42144751539)
passed all five required checks at head
`5bef195782df3ac38f67968a21a5850ab560c585` (base
`ed8cc1320ad312165285bae6657a8579d1855691`). That change is now on main as
`bb472a4a52b6add320ed886bd9cf4d2a7389d9a5`; its backend tree hash is
`87d3e7bab38d47ac232f0bd723ccddffbd7f5c89`. Relative to the audited PR116
main, four backend paths changed: `backend/ai/candidates.mjs`,
`backend/gateway/postgres.test.mjs`, `backend/tests/ai-provider.test.mjs`, and
`backend/tests/candidates.test.mjs`. The runtime change keeps arbitrary
user-entered pattern text out of AI candidate payloads while preserving the
stored value; the tests cover both candidate projection and direct provider
serialization. Gateway, storage and operations lockfiles and
`backend/images/requirements.txt` remain unchanged, so the prior dependency
scan inputs are still the current inputs.

The PR120 `validate` job passed. It ran `node scripts/harness-check.mjs` with
92/92 JavaScript tests passing; the harness also runs the Python image decoder
tests. It also passed the simulator selector and Python test groups for
simulator clone, bounded commands, and performance summarization.

The PR120 `postgres` job passed `bash backend/tests/run-tests.sh`, then the real
PostgreSQL gateway/erasure tests and operations test:

```sh
GATEWAY_PG_TESTS=1 node --test --test-concurrency=1 backend/gateway/postgres.test.mjs backend/gateway/erasure-postgres.test.mjs
OPS_PG_TESTS=1 node --test backend/operations/postgres.test.mjs
```

The migration suite passed fresh install, populated v001 upgrade, replay, atomic
rollback, checksum, and schema/security contracts. The gateway/erasure PostgreSQL
tests passed 2/2 and the operations PostgreSQL test passed 1/1.

## Coverage by T056 area

| Area | Executed coverage |
| --- | --- |
| IDOR and cross-tenant ownership/relations | PostgreSQL `schema.sql`, `api.sql`, `outfits.sql`, `planner.sql`, `trips.sql`, `offline-sync.sql`, `wear-history.sql`, and `purchases.sql`; real gateway PostgreSQL test “real PostgreSQL gateway bootstrap, owner isolation, replay, session revocation and deletion guards” |
| Storage and upload access | PostgreSQL `images.sql` and `recognition-drafts.sql`; HTTP test “recognition draft upload and reads stay on the authenticated private target”; image decoder, recognition, and image retention tests |
| Upload, input, and usage limits | Image decoder and `images.test.mjs`; PostgreSQL `ai-runtime.sql`; AI tests “invalid image/count and oversized input do not dispatch”, “large valid image stays within the transport limit without regex stack overflow”, bounded repair/timeout/usage tests |
| Tokens and authenticated operations | Gateway HTTP OTP/session tests, including “each RPC requires current managed session and deletion gate; logout invalidates next request” and “caller cannot choose RPC function, owner, auth origin, token headers or unbounded payload”; gateway session revocation/deletion PostgreSQL test; signed-MFA operations PostgreSQL test |
| Prompt-injection boundary | AI evaluator tests validate 120 labeled synthetic cases including five instruction-injection cases. Candidate tests verify custom free-text patterns, including instruction-like text, become unknown in AI input while remaining unchanged in stored metadata; provider serialization tests verify the same for owned garments and purchase candidates. AI runtime/provider tests reject unauthorized or invalid results and fail closed. |
| Dependency scan | Separate fresh scans on 2026-11-06 found zero known advisories for the existing gateway, storage, and operations npm lockfiles and the pinned Pillow dependency. CI dependency installation uses `--no-audit`; the scans were performed separately. |

The active staging gateway's actual decoder interpreter was checked read-only on
2026-11-06: Python 3.12.3 with Pillow 13.0.0. This supersedes the older Pillow
12.3.0 runtime observation in [the image dependency note](T056-image-dependencies.md).

## Remaining limit

The injection cases exercise deterministic trust boundaries: notes are removed
before provider input, and results are checked against owned, eligible garments.
They do not measure model resistance to instructions embedded in image pixels.
No provider call was made because live AI remains disabled. This specific
image-pixel behavior is unmeasured; no broader external pentest requirement is
inferred here. Keep T056 In Progress until the required matrix has been reviewed
and any critical/high findings are resolved.
