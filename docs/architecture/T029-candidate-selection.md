# T029 — Outfit candidate selection

The outfit executor now applies `selectCandidates` before authorization and provider
transmission. The trusted T027 runtime must return the current wardrobe as metadata
only: `id`, `user_id`, `availability`, `archived` (explicit boolean), `category`, and
optional `colors`, `pattern`, `seasons`, `formality` using the recognition vocabulary.
The owner comes from the leased job's `user_id`, never a client-supplied input field.
Missing ownership/status excludes a row; malformed eligible metadata or duplicate
IDs fail closed. The runtime should query owner-scoped records and must not load
image bytes for outfit generation. There are no new dependencies or migrations.

Input also contains `count` (1–10), optional `pinned_garment_id`, optional
`preferences: { colors: [], seasons: [] }`, and optional
`occasion: { formality: 1…5 }`. These are the currently supported ranking signals;
free-form style labels are not inferred. Absent optional metadata remains unknown.
An absent, foreign, archived, or unavailable pin stops the job before dispatch.

Selection is deterministic, capped at 40 regardless of request count. It reserves
the eligible pin, then round-robins ranked category buckets, preserving every
represented category (including rare shoes, dresses and jumpsuits). Preference
matches add two points each; known formality adds `5 - abs(target - garment)`.
These are transparent heuristics, not measured style-quality claims. ID breaks
ties, so database row order does not affect selection. Missing categories are not
invented; a small wardrobe returns fewer candidates. This step selects garments,
not complete outfits; completeness, diversity and final outfit validation belong
to the subsequent domain validator.

Only allowlisted metadata and normalized ranking context enter the executor's
provider input. Images, image URLs, prices, owner IDs and arbitrary raw fields are
omitted. Zero images are sent: outfit recommendation uses metadata; real garment
photos remain available to the app's collage presentation. The provider also caps
direct calls at 40 and projects garment metadata. A future thumbnail strategy must
retain explicit count/byte limits rather than serializing whole wardrobe records.

After generation, the executor re-reads the full eligible wardrobe and checks
returned IDs against both current eligibility and the candidates actually sent.
It does not re-rank the current wardrobe: an independent addition must not
invalidate a still-eligible returned garment. Atomic revalidation at persistence
remains the trusted runtime's responsibility.

## Verification

`node scripts/harness-check.mjs` includes offline candidate tests: ownership,
missing status, laundry/archive/unavailability, invalid pins, duplicate IDs,
preference/occasion ranking, category coverage, deterministic ordering and a
1000-item wardrobe through the executor and provider serializer with injected
transport. That request has 40 candidates, eight categories, its pinned item,
no images/private fields, and less than 10 KB of serialized context. Tests also
cover ownership changes during generation and additions after selection.

No paid API, deployment or external account was used. Production integration still
requires the T027 runtime to supply the documented ownership/status metadata and
map profile/context values to this input contract. Verify on staging with the
owner-approved runtime/provider; check candidate IDs and payload sizes without
logging private payloads. macOS CI must run the existing Xcode build/tests; Xcode
and production services are unavailable in this Linux sandbox. No iOS files changed.
