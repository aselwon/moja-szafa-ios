# T041: weekly outfit planner

Plans and actual wears are separate records. The planner can create, move, delete and undo deletion of an owned saved outfit on a local calendar day. None of those actions writes a wear or changes cost per wear. Only the explicit confirmation dialog calls `confirm`; future dates cannot be confirmed.

## API and consistency

`POST /rest/v1/rpc/api_v1_planner` follows the existing gateway RPC envelope. The standalone `backend/api/openapi-planner-v1.json` defines list/create/move/delete/restore/confirm. The gateway must load this checked-in contract into its RPC allowlist.

Migration 019 adds a timezone to plans, a live-only uniqueness constraint and private confirmation receipts. Lists are bounded to 40 rows with a UUID cursor and a date range of at most 366 days. Clients sort visible rows by local date. Create/move accepts today through 366 days ahead in the supplied IANA timezone. Dates remain date labels when a device changes timezone.

Mutations use operation UUID plus exact-body replay and optimistic plan versions. A plan lock serializes confirmations. The private `(owner, plan, local day)` receipt additionally deduplicates different operation IDs from different devices. Confirmation locks the outfit, checks the displayed outfit version, and calls the existing `api_v1_save_wear` in the same transaction with a distinct child operation. Its garment IDs become the immutable historical snapshot. Moving/deleting/restoring the plan does not move/delete that wear. Moving a confirmed plan to another day requires a new explicit confirmation for that day; returning to the original day reuses its receipt.

The planner has its own narrow update trigger: a deleted plan can only be restored unchanged. Identity is immutable and every update increments its version. Existing irreversible garment and wear tombstone triggers are unchanged. Undo of a plan action never undoes actual wear history.

## Native flow

A reusable SwiftUI planner is linked from Today and Outfits without replacing either screen. The two entry points share one model. It has week selection, saved-outfit selection, real garment collages, pagination, empty/loading/error/offline states, move/delete/undo and explicit wear confirmation. PL/EN strings support native Dynamic Type and VoiceOver controls.

Before a mutation is sent, its exact intent is atomically written to a protected account-and-gateway-scoped journal. Ambiguous transport errors retain it across relaunch; other mutations are blocked until replay resolves. Definitive validation/version failures permit a fresh intent. Corrupt journals fail closed. Authentication binds requests to the original account, and account deletion removes its planner journal. Superseded week requests cannot publish rows, errors or loading state over the latest selected week.

## Validation and remaining integration

Database coverage includes no wear on planning/move/delete, local-day preservation, future rejection, immutable captured membership, foreign owner denial, optimistic conflicts, replay, restore, bounded pagination and four concurrent confirmations with different operation IDs. The entire disposable PostgreSQL 15 fresh-install/upgrade/security/concurrency/recovery suite passes. Swift tests cover relaunch replay, separate account journals, conflicting intents, corrupt journals, undo without wear, timezone dates, wire payload and out-of-order week responses. Debug build-for-testing passes. All seven PlannerTests passed on the dedicated iPhone 17 Pro / iOS 26.5 simulator with zero failures, skips or runtime warnings; result bundle: `/private/tmp/szafa-planner-runtime.xcresult`.

T041 is integrated with the T038 wear-history calendar and the live gateway composition. The planner keeps actual wear history separate from planned outfits; its confirmation flow is the only path that creates a wear record.
