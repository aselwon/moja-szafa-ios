# T034 — AI cost admission and emergency stop

Migration 016 adds database-enforced admission to the existing durable job queue.
No new dependencies, provider calls, cloud changes or product prices are included.

## Accounting contract

A private singleton policy serializes admissions across users. Missing policy or
`enabled = false` refuses new reservations. Trusted operators configure monthly
per-user units, a cumulative global budget, currency, pricing version and a
conservative upper bound for one provider request. The worker cannot edit policy.
The UTC calendar-month quota includes settled usage from that month and **all**
outstanding reservations, including older months. Failed/cancelled/dead-letter
jobs release user units through the existing atomic queue settlement.

Admission reserves `request_cap_microunits × max_attempts × 2` in the global
budget, using integer arithmetic. At most three queue attempts and one JSON repair
per attempt are permitted; increasing a job's retry ceiling is rejected. The cap
must cover the more expensive configured operation, maximum metadata/image input,
output limit, and any provider-specific billable units. It is an operator-approved
upper bound, not an estimated invoice or an invented price. Overflows fail closed.
Idempotent enqueue does not create another reservation. The quota and budget
check, hold and job creation share one transaction.

The existing dispatch RPC now checks both consent and cost authorization, including
calls immediately before the provider and its one repair. Disabling policy stops
new dispatch authorizations and terminates claimed jobs with released user units.
Already authorized requests cannot be recalled. Old jobs without priced holds are
refused. The consent-only internal function is no longer executable by the worker.

Before any dispatch authorization, cancellation/failure/deletion refunds the global
hold. After authorization, the entire conservative envelope stays committed even
on failure, timeout, account deletion or lost completion. Success settles user units
and retains this envelope. This intentionally overcounts possible provider spend;
it never equates a failed job with free provider usage. No per-account data needs
to survive deletion to retain the aggregate committed budget. Provider telemetry
continues recording actual token counts separately. There is no automatic invoice
reconciliation or refund of the difference between envelope and actual charges.

The HTTP executor does not retry ambiguous failures. Process timeout or lease loss
can still cause bounded queue retries and duplicate provider charges. Without
provider idempotency, **exactly-once external billing is not guaranteed**. The full
retry envelope is reserved before the first call.

## Operator procedure

Keep AI disabled until approved provider pricing, T015 disclosure, runtime hooks
and staging verification exist. Install the private policy using the migration
owner's controlled database access; synthetic fixture values are only for tests.
Choose quota and budget with the product owner. Track committed/budget, failures,
unknown usage, dead letters and provider invoices using the existing telemetry sink.
Stop dispatch by setting `enabled = false`; retain holds and let workers finish or
expire leases. Never reset the cumulative committed counter on calendar rollover.
Raise the cumulative budget only with explicit owner approval. For changes in
currency, provider pricing or token/image caps, disable AI, drain/cancel pending
jobs and reconcile in-flight invoices before installing a new envelope. Do not
change currency underneath existing commitments. Backups must preserve the policy
and holds; reconcile provider spend before re-enabling a restored queue.

## Verification

- Local `node scripts/harness-check.mjs`: passed (42 tests plus existing checks).
- Added `ai-costs.sql`: quota/global rejection, replay, pre-dispatch refund,
  failed-job release with unknown billing retained, success settlement, kill
  switch, missing configuration, retry bounds, deletion and privilege checks.
- Added `ai-cost-concurrency.sh`: two owners contend for one remaining global
  envelope; exactly one admission may commit. Existing job tests retain their
  crash recovery, retry exhaustion and atomic settlement assertions.
- Both new suites run in `backend/tests/run-tests.sh` for fresh and upgraded
  databases through the existing PostgreSQL CI job. Local execution is blocked:
  no `psql` installation and Docker socket access denied. Run that script with
  PostgreSQL 15 and require green CI; these SQL tests are not claimed as passed.
- macOS build/tests and hosted CI need external verification. No iOS code changed.
- Before production, verify approved envelope against actual provider billing,
  concurrent admission, stop during queue activity, restart and invoice telemetry
  on staging with authorized access. This sandbox made no paid API calls.
