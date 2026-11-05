# T053: consent-based diagnostics and operational metrics

## Data and consent

The Profile → Diagnostics and analytics screen offers two independent opt-ins,
initially disabled: diagnostic reports and activation analytics. The server owns
consent revisions. A changed choice is persisted with an immutable operation ID;
an ambiguous request retries that operation, then fetches current consent again.
An old acknowledgement cannot enable collection. Local collection pauses before
any consent change is sent, including an offline withdrawal. A failed withdrawal
is shown as pending, not as already confirmed by the server.

The diagnostic queue belongs to one account and gateway, is excluded from device
backups, uses iOS file protection, and holds at most 100 events. Ingestion uses
batches of at most 20 and stable event IDs. Logout and confirmed account deletion
invalidate the recorder and erase its journal. Account changes cannot reuse a
previous account's recorder. Foreground collection refreshes consent and flushes
once per minute; a suspended app is not a guaranteed background uploader.

Diagnostic fields are limited to RPC name, outcome category, elapsed milliseconds,
session marker, and sanitized crash binary UUID/text-segment offset/build/CPU
architecture. Synchronization measures the complete pull/outbox/pull cycle and
records its failures. HTTP bodies, garment names, photos, email addresses, tokens,
full URLs, raw error strings, raw MetricKit reports, memory addresses and file
names are not uploaded. Server activation markers are derived from committed
counts of five garments or three outfits; clients cannot assert completion.

Records are retained for 30 days. Withdrawing a category deletes its retained
records; hard account deletion cascades and exports contain the account's own
telemetry and consent history. A separate consent audit remains part of the
account export until account deletion. The gateway calls `app.telemetry_prune()`
once a minute, deleting at most 10,000 expired rows per call; ingestion also prunes
that account. Migration 025 must be followed by reapplying the conditional grant
in `backend/deploy/neon-bootstrap.sql`. The gateway receives EXECUTE on that fixed
function plus schema USAGE to resolve its name (the service role is NOINHERIT),
not direct telemetry table or report access. The gateway-role regression applies
the real bootstrap against isolated provider-shaped fixture tables and executes
the maintenance call as that limited role.

MetricKit delivery is controlled by iOS and may be delayed or absent. Only app
binary frames are retained. A payload whose beginning predates the continuously
verified consent window is discarded, including reports spanning logout or a
consent revision. Reports from supported legacy iOS 14+ MetricKit JSON are parsed;
new iOS 27-only typed APIs are not required. See Apple's
[legacy call-stack JSON contract](https://developer.apple.com/documentation/metrickit/mxcallstacktree/jsonrepresentation%28%29/).

## Operational report

Gateway HTTP measurements are anonymous aggregates by fixed route label, UTC day,
outcome and duration bucket. They include logical RPC failures returned as HTTP
200 and aborted requests. No account/IP/request identifier is retained. The file
has mode 0600, a seven-day window, a fixed cardinality cap and an explicit dropped
sample count. Set `OBSERVABILITY_DIRECTORY` to an absolute private directory
owned by the gateway service. Without this setting metrics remain in memory.

With existing operator database credentials supplied through the environment,
run `node backend/observability/report.mjs`. Never put a database URL on the command
line or in a committed file. The read-only report contains opt-in event counts and
latency percentiles, activation counts, AI queue status/end-to-end latency, provider
latency/token coverage, current call-credit limits and warning states. Optional
`OBSERVABILITY_DIRECTORY` adds the gateway histogram. Owner credentials are needed
for this operator CLI; it is not a public HTTP endpoint or the T054 operator panel.

AI prices are estimates from actual recorded input/output token usage and the
2026-11-05 [Cloudflare rate snapshot](https://developers.cloudflare.com/workers-ai/platform/pricing/).
Unknown usage remains unknown. Invoice cost is null because account-wide free
allocation and other traffic are not observable here. Global/user call credits
are not currency limits. Warnings at 80% and 100% refer to call credits only.
This change neither enables AI nor changes the existing 10-global/4-user policy,
purchases a plan, or promises a $5 billing cap. The report emits local warning
states; external notifications are not configured by this task.

## Crash symbols

Every app and widget build produces dSYMs. CI attaches UUID manifests and symbol
bundles for each tested configuration/platform with commit SHA provenance and a
30-day artifact retention. Simulator and device UUIDs differ: never substitute
simulator symbols for a device crash. Before an artifact expires, archive the
symbols for every installed/supported build in a private durable location:

```sh
python3 scripts/crash-symbols.py archive --source /path/to/dSYMs --archive /private/symbols --commit FULL_COMMIT_SHA
python3 scripts/crash-symbols.py symbolicate --report /private/sanitized-crash.json --archive /private/symbols
```

Use only a sanitized event's JSON as the input report. The archive is keyed by
binary UUID and architecture, refuses conflicting immutable symbols and verifies
SHA-256 and actual DWARF UUID before calling `atos`. Missing or mismatched symbols
are reported explicitly. Symbolication is local; no reports are sent to a third
party. Retain supported release symbols beyond the CI artifact expiry. The
macOS regression compiles a real tiny binary, archives its dSYM and resolves a
known function offset; it also checks corruption and missing UUID rejection.

## Verification and remaining real-world evidence

Migration/SQL tests exercise consent CAS/replay, owner separation, withdrawal,
retention, deletion/export, malformed payload rejection and activation thresholds.
Gateway tests measure real local HTTP requests. Native tests cover consent and
retry lifecycle, bounded queues, actual RPC instrumentation and crash redaction.
Symbol tests validate actual DWARF/atos behavior. Current results are recorded in
the PR, rather than inferred from this document.

Opt-in sessions and delayed MetricKit payloads do not provide a trustworthy
whole-population crash-free-session denominator. This report intentionally does
not claim the beta's 99.5% crash-free target. Signed physical-device MetricKit
receipt, real beta reliability and production billing evidence remain later
acceptance work; synthetic tests are not replacements for those observations.
