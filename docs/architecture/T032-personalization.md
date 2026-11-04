# T032 — AI preferences and outfit feedback

Suggestion cards offer an explicit “Save and rate” action (no wear is recorded). Both tabs share one account-scoped pending-intent model. The Outfits screen exposes AI preferences and a rating action for each saved outfit. Preferred colors and like/dislike ratings influence candidate ranking. Excluded categories are hard constraints. Ratings never create wear events, modify their snapshots, or affect cost per wear.

## Enforcement

Migration 024 adds an owner-scoped revision and `api_v1_personalization`. All preference, feedback and reset mutations require an operation ID and expected revision. A live profile lock serializes mutations with reset/account deletion. Exact retries return the original acknowledgement; a new operation based on an old revision is rejected. The client reads current state after every acknowledgement so a cached response cannot undo another device's reset.

Worker hydration removes excluded categories and computes a bounded score from ratings of live saved outfits. Only the score influences local ranking; feedback reasons are never included in provider metadata. Preferred colors remain soft. Current exclusions also filter previously completed results as whole outfits, reject excluded pins, and prevent saving newly excluded suggestion contents. Existing saved outfits and wear events remain available.

Reset deletes stored AI colors, exclusions and ratings across devices and advances the revision. It does not erase wardrobe data, wear history, or device-local profile settings. A delayed pre-reset mutation cannot recreate personalization without reloading and a new explicit action.

## Network failures

The immutable pending request is stored in a protected, backup-excluded journal scoped to gateway/account. Reopening the app preserves its operation ID. Retry sends that exact request; a corrupt journal disables changes. Account deletion removes the journal. A definitive conflict clears the pending request and requires a fresh read instead of silently rebasing user intent.

## Verification

- PostgreSQL tests cover owner isolation, exact replay, stale revisions, reset fencing, untouched wear history, filtering completed results and real worker hydration without a provider call.
- Managed gateway integration exercises save, replay, foreign-account reads, reset and stale-write rejection over HTTP with the restricted database role.
- Native runtime tests cover timeout/relaunch retry, fresh-state reads after cached acknowledgements, stale updates and corrupt local storage.
- Candidate tests verify feedback ranking and absence of feedback text/scores in model metadata.

No paid service or live AI execution is enabled by this change. Applying the migration and deploying the gateway are separate operational steps; this document does not claim a live deployment.
