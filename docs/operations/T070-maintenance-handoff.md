# T070 — Maintenance handoff

**Evidence snapshot:** 2026-11-05, repository `main` at `d9af36efe7d6f24e84b8412f9658c5ef8cccee45`.
This is a repository and staging handoff, not a production release record. A
role is not an assigned person: all named operational owners below remain
**UNASSIGNED** until the product owner records actual names and contact routes
outside this repository.

## Ownership and escalation

| Responsibility | Owner | Current handoff |
| --- | --- | --- |
| Repository, protected branches, CI and release source | UNASSIGNED — release engineer | Require review and five green required checks on the exact PR head, current `main` base, and no unresolved review threads before merge. Preserve the merged commit SHA in release evidence. |
| Database migrations and gateway runtime | UNASSIGNED — backend operator | Follow [T008 migration guidance](../architecture/ADR-001-backend.md) and the deployed state in [T060 staging evidence](T060-staging-gateway.md). Use a migration-authorized connection and a separately reviewed deployment plan. |
| Backups, restore and deletion replay | UNASSIGNED — recovery operator; independent reviewer also UNASSIGNED | Use [T055 backup and restore](T055-backup-restore.md). Stop reopening on a missing/inconsistent deletion journal, missing object bytes, failed hash checks, or unverified identity recovery. |
| Alerts, incidents and first 72 hours | UNASSIGNED — on-call operator | [T053 observability](T053-observability.md) provides local aggregate reporting, not an alert delivery integration. No recipient or on-call schedule is configured. |
| Privacy requests and erasure | UNASSIGNED — privacy operator | Use [T017 runtime and activation gates](../architecture/T017-managed-erasure-runtime.md). Do not enable deletion routes/workers until the independent journal, storage permissions, provider identity controls, backup retention and restore replay are ready. |
| Secret issuance and rotation | UNASSIGNED — security/operator role | Use the credential inventory procedure below. Do not put credentials or secret values in Git, issue comments, command arguments, screenshots or logs. |
| Product decisions and customer support | UNASSIGNED — product owner/support owner | Resolve the open items below and record the approved decision and effective date in the existing decision register. |

The product owner must assign people and escalation routes before a production
release. Role labels are placeholders, not implied appointments. Contact details,
credentials and customer data belong in approved private systems, not this file.

## Routine change and migration release

1. Start from current `main`; confirm the migration number and deployment state
   against the repository, open PRs and the target's migration ledger. Never edit
   a migration that has already been applied. Add a forward migration and its
   tests instead.
2. Require review and all five required CI gates on the exact proposed head:
   repository validation, Debug, Staging, Release, and PostgreSQL lifecycle.
   The workflow's iOS jobs use isolated simulators. A canceled, skipped, stale,
   or different-head check is not a pass.
3. Before a production change, obtain explicit environment authorization and a
   verified, recoverable backup. Review the exact source SHA, migration SQL,
   checksum and application compatibility. Do not run tests, development
   bootstraps, or the managed-auth test shim against a live service.
4. `backend/migrate.sh` applies selected pending migrations in one transaction,
   takes an advisory lock, records SHA-256 checksums, skips unchanged applied
   migrations, and rejects a changed historical checksum. The current snapshot
   defaults to target `032`; an explicit lower target does not roll back newer
   applied versions. Run the reviewed command only from the approved operator
   context, using the normal protected libpq configuration (never a URL in the
   command line). No destructive down migration exists.
5. Verify the resulting ledger/checksum and the release-specific health,
   authentication, ownership and privacy smoke checks. If deployment fails,
   fence traffic/workers as needed and use a separately reviewed forward fix or
   restore plan. A database rollback alone may not undo external effects; do not
   promise binary rollback or reverse an applied migration by editing SQL.
6. Record operator, reviewer, UTC times, source SHA, target environment, applied
   migration versions/checksums, check links, smoke results and any rollback or
   forward-fix evidence in a private release record. Never include secrets or
   personal data.

The 2026-11-05 staging review records an active gateway whose public health check
passed. Its migration ledger contains versions 001–026 and 028 (27 rows); every
recorded checksum matched the repository migration file. It has zero profiles,
AI and image AI disabled, and global/per-user call-credit ceilings of 10/4. The
separately installed macOS deletion-journal replicator passed a synthetic
acknowledgement check. This was not a full restore drill or provider identity
cascade test. Positive authentication and the native signed-in flow remain
unverified. This is staging evidence, not production acceptance. Recheck the
live ledger before any staging migration because the snapshot can become stale.

## Runtime configuration and secret rotation

Store server configuration in the host's root-owned, restricted environment
file or approved secret manager; the staging systemd unit points at
`/etc/moja-szafa/gateway-staging.env`. The feature unit uses
`/etc/moja-szafa/gateway-feature.env`. Neither file belongs in a release archive
or repository. Keep separate credentials and databases per environment.

Inventory variable **names**, owners, environment, last-rotated date and next
review date in the private secrets manager. Relevant names in the current
runtime include `DATABASE_URL`, `PGSSLROOTCERT`, `PRIVATE_IMAGE_DIRECTORY`,
`EXPORT_DIRECTORY`, `CLOUDFLARE_WORKERS_PLAN`, `CLOUDFLARE_ACCOUNT_ID`,
`CLOUDFLARE_AI_TOKEN_FILE`, `OPS_ISSUER`, `OPS_AUDIENCE`, `OPS_JWKS_URL`,
`OPS_PUBLIC_ORIGIN`, `OPS_DATABASE_URL`, `NEON_PROJECT_ID`, `NEON_BRANCH_ID`,
`NEON_MANAGEMENT_KEY_FILE`, `ERASURE_RUNTIME_ENABLED`,
`ERASURE_JOURNAL_DIRECTORY`, `ERASURE_ACK_DIRECTORY`,
`ERASURE_REPLICA_ID`, and `ACCOUNT_DELETION_ENABLED`. Names vary by service;
consult that service's runbook before changing configuration.

Rotation procedure: assign an authorized operator and reviewer; issue a new
least-privilege credential through its provider; install it using the protected
channel with restrictive file permissions; update only the intended service;
restart/reload only after its validated config is ready; verify health and a
non-destructive authenticated smoke test; revoke the old credential; then record
the time, credential class and result without recording the value. For database
logins, retain the old login only during the approved overlap and revoke it
after the replacement is confirmed. For erasure management credentials, do not
activate deletion until the new identity has passed the trust checks. There is
no automation or rotation cadence configured today.

## AI controls and incident stop conditions

The tested/staging policy snapshot is disabled, with global and per-user
application call-credit ceilings of 10 and 4. These are not currency caps, and
the values must be re-read from the authorized policy record before operation.
The runtime also requires consent and an enabled policy immediately before
dispatch. Do not enable a provider or increase a ceiling as part of incident
response without explicit owner approval, reviewed configuration and a cost
monitor.

If AI spend, consent, or dispatch is uncertain, stop the worker through the
approved service operator, preserve its queue and audit/usage records, and leave
the policy disabled. Do not delete reservations or reset counters to make the
service appear healthy. T054's local panel is not live operator access: no
MFA-capable SSO proxy/operator identities are provisioned in the documented
state, and migration 027 is not recorded as deployed. Do not use it to change
live policy until its deployment gates pass.

## Privacy and recovery stop conditions

- Never reopen after restore until deletion evidence has been replayed through a
  final watermark, removed object versions are verified absent, and stale
  sessions/capabilities are revoked. A relational replay is not proof that
  object bytes, provider identities, caches or external backups were erased.
- The managed erasure runtime and integration tests exist in the repository,
  but are not activated in staging or production in this evidence snapshot.
  Required management credentials, Apple identity revocation support where
  applicable, independent journal durability and a restore/replay drill remain
  open gates.
- T055's older statement that the T017 service/journal are “not present” is
  superseded by the T017 managed-erasure runtime implementation and local tests.
  This supersession does not mean the runtime is deployed or that restore
  acceptance passed.
- Do not claim measured production RPO/RTO, complete physical erasure from
  backups, stable uptime, paid-provider limits, or production readiness without
  the corresponding dated operational evidence.

## Open handoff items

Observed 2026-11-05; all have no assigned individual owner. Update each row only
when the external decision or evidence actually exists.

| Item | Needed before | Owner | Next action / evidence |
| --- | --- | --- | --- |
| Assign named primary and backup operators for each responsibility above, including incident contacts | Any production on-call or customer support | UNASSIGNED — product owner | Record appointments and escalation route in private operations directory. |
| Configure alert delivery and a 72-hour release duty schedule | Beta/release monitoring | UNASSIGNED — operations owner | Choose recipients, test delivery, establish coverage and escalation response. Local reports alone are not alarms. |
| Approve paired database/object backup policy, retention, keys and deletion-journal failure domain | Production data | UNASSIGNED — product/recovery owners | Validate provider capabilities; complete isolated restore and deletion replay; measure RPO/RTO. Proposed targets in T055 remain unapproved/unmeasured. |
| Provision MFA SSO/proxy, operator registry and least-privilege login for T054 | Live operations panel | UNASSIGNED — security/backend owners | Complete the T054 deployment gates; keep the panel unavailable until verified. |
| Activate and verify erasure runtime, management access, Apple revocation path and independent journal | Account-deletion operations | UNASSIGNED — privacy/backend owners | Complete T017's explicit activation and recovery checks without real customer data until authorized. |
| Establish stable staging and production endpoint/auth/storage configuration | Native end-to-end and production release | UNASSIGNED — product/backend owners | Resolve D04 and D11; validate positive signed-in flows, image permissions, backup and alerts. Current temporary staging health checks are insufficient. |
| Set a supported-device and maintenance review cadence | Release policy | UNASSIGNED — product owner | Resolve D08 and D11; proposed cadence: review this handoff quarterly and after every incident, migration, provider/credential rotation, or material runtime change. This is a proposal, not a scheduled process. |

This page is an index and operating boundary, not authorization to access an
account, deploy a service, rotate a live secret, send customer communications,
or run a production migration. The owner must replace role placeholders and
close external gates with evidence before T070 or production readiness is
claimed.
