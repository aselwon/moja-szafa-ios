# T010 — Durable jobs

## Implemented boundary

Migration `004_jobs.sql`, the dependency-free Node worker and the Swift status
client implement durable scheduling. No worker has been deployed and no AI
provider is configured. T007 staging access is still required. Actual image
analysis, provider selection, consent enforcement and budget admission belong
to their feature tasks; this task does not simulate a completed analysis.

The queue uses the existing PostgreSQL tables and a private payload/result table.
Only a trusted feature service can call `app.jobs_enqueue(owner_id, operation_id,
job_kind, payload, units)`. It must derive the owner from verified authentication,
validate references/consent and admit the budget before calling. This function is
not granted to `authenticated` and is not a public client endpoint. Units are a
server decision. This is reservation accounting, not an implemented pricing or
quota policy. Keep the operation UUID and payload unchanged on admission retries.

Enqueue commits job, input and a single usage reservation together. Concurrent
retries of `(owner, operation UUID)` return the same job; changed kind, input or
units fail. Payloads should contain stable private resource IDs, never expiring
signed URLs, raw image bytes or credentials. Results remain private for future
feature-specific validation/retrieval; the status endpoint does not expose them.
All payloads/results cascade on physical account deletion.

## Execution and failure semantics

| Transition | Behavior |
| --- | --- |
| Claim | `FOR UPDATE SKIP LOCKED`, 60-second lease, new UUID fence, increment attempts. Default maximum is three attempts. |
| Execution | Adapter runs in a child process, killed after 45 seconds. Database subprocesses have a 10-second timeout. No open database transaction spans execution. |
| Success | Check live token and expiry under a row lock; atomically store result, mark succeeded, settle the existing reservation. |
| Explicit retry / timeout | Return to queue with a delay of `5 × attempt` seconds; no new reservation. |
| Process crash | Next poll recovers an expired lease with the same backoff and a fresh token. A final expired attempt becomes dead-letter. |
| Permanent failure / exhausted attempts | Mark dead-letter, record safe error code and finish time, release reserved units in the same transaction. |
| Late or duplicate completion | Return false without changing result, state or units. |
| Lost database response | Worker makes no compensating settlement or extra provider call; later polling resolves the durable state. |

Reservation `expires_at` alone must **not** trigger a refund of queued/running
work. Only terminal queue transitions settle/release these reservations; claim
extends expiry metadata. This prevents a separate expiry sweep from refunding
work that is being recovered. There is no automatic dead-letter replay. Inspect
safe IDs/status/error codes with authorized backend access, resolve the cause,
and explicitly admit a new operation through the feature service if needed.
Never requeue a terminal job by editing its status or reuse a released reservation.

The guarantee is one local usage settlement, not exactly-once external execution.
Use the durable job UUID as the provider idempotency key when supported. A crash
or timeout after external acceptance can incur another provider charge when the
provider has no idempotency support; retries are bounded, not cost-free. Adapters
must declare only safe failures as `retry`, recheck current consent/ownership
immediately before sending private data and return `permanent` on invalid input
or revoked permission. External billing and consent integration require the
future real provider adapter and its tests.

## Worker installation contract

Requires existing Node 22 and PostgreSQL 15+ `psql`; no npm dependencies. A process
supervisor should run/restart the worker. Configure libpq using secure service /
password files and a dedicated backend identity authorized for the queue RPCs;
never expose that identity to iOS or place credentials in argv or the repository.
Run after applying migrations in an authorized environment:

```sh
export PATH=/home/harness/.local/bin:$PATH && node backend/worker/worker.mjs /absolute/path/to/approved-adapter
```

The adapter is an **executable**, invoked directly without a shell or arguments.
It receives one JSON job on stdin: `id`, `user_id`, `kind`, `lease_token`, `attempt`,
`input`. It writes exactly one JSON object on stdout:

- `{"outcome":"success","output":{...}}` for a validated result;
- `{"outcome":"retry"}` for a known transient failure;
- `{"outcome":"permanent"}` for a terminal failure.

Do not log private data on either stream. Output is limited to 1 MiB. Nonzero exit,
malformed output or unknown outcomes become permanent failures; timeout follows
the bounded timeout policy. The executable must do its work in its own process
(or `exec` its runtime), not spawn detached children that survive termination.
There is intentionally no default fake or live paid adapter. SIGTERM stops new
claims and allows the current bounded attempt to finish; abrupt termination
leaves recovery to the database lease. Start without an adapter fails closed.

## Relaunch and status contract

`api_v1_list_jobs` is documented in OpenAPI and exposed by `APIClient.jobs` using
async/await. Authentication scopes every page to the live profile. Pagination is
UUID ascending with limits 1–100, as in T009. Start with `cursor: nil` on every
refresh/relaunch and follow `next_cursor` to rediscover all jobs without retained
in-memory IDs. Pages are not snapshots: restart pagination on refresh. Responses
include only ID, kind, status, attempts and a safe error code. No lease, input,
result or other owner's data is returned. Errors use code/message/request_id.
Feature UI polling/presentation will use this client when AI screens are built;
this foundation does not claim an implemented analysis screen.

## Verification and outstanding evidence

- `node scripts/harness-check.mjs` includes executable worker tests: idle polling,
  persisted input/fence forwarding, explicit retry classification, malformed
  results, ambiguous completion and killing a hung adapter.
- `bash backend/tests/run-tests.sh` includes clean install, v003-to-v004 upgrade,
  migration replay and SQL queue tests. Tests cover deduplication/conflicts,
  owner isolation/privileges, lease expiry/backoff, stale completion, atomic
  result/settlement rollback, bounded retries, permanent failure, final-attempt
  crash, dead-letter refund and result preservation.
- `jobs-concurrency.sh` races enqueue and claim through separate committed
  connections, exits both worker connections, recovers in a third connection,
  and reads the succeeded status as a fresh authenticated session. It asserts
  one job, one settlement and the durable result after replay.
- XCTest adds new-client status recovery and malformed response validation to
  the existing API client suite. The unchanged macOS CI job runs these tests.

This sandbox has no PostgreSQL tools, Swift or Xcode. SQL and XCTest execution
remain **unverified**, rather than skipped as successes. Require the PostgreSQL
CI job and all macOS build/test configurations to pass. Then, with authorized
staging and a real adapter, kill the worker after claim and after external
completion, restart it, reopen the app's eventual AI screen, verify status/result
and one local reservation settlement, and separately inspect provider charges.
No accounts, deployments, paid calls or external acceptance were performed.
