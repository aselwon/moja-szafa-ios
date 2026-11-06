# T018 — Policies and support publication dossier

Version 0.2. **Internal draft; publication and release blocked.**
This is preparation for T018 only, not evidence of published policies, legal
approval or an operational support channel. Repository implementation details
below are not legal conclusions or proof of a configured service. No publisher
identity, controller contact, or approved public policy/support URL is supplied.

## Review package

- [Privacy Policy — PL/EN](T018-privacy-policy.md)
- [Terms — PL/EN](T018-terms.md)
- [Support — PL/EN and internal operating procedure](T018-support.md)
- [Recipients and subprocessors register](T018-recipients.md)

These files are internal review sources, outside app resources. Do not publish
this directory wholesale or bundle it as release policy content. Missing facts
are recorded here rather than replaced with invented identities, email addresses,
URLs, contractual terms or numeric retention promises. The absence of literal
placeholder tokens is **not** proof of release readiness.

## Implementation-to-disclosure traceability

`AppDependencies.live()` reads the backend URL from the application bundle and
returns an unconfigured repository when configuration is empty or invalid. This
documents the code boundary only.

| Flow | Repository evidence | Disclosure boundary |
| --- | --- | --- |
| App identity and sessions | `docs/architecture/T013-authentication.md`, `MojaSzafa/Data/SessionStore.swift` | Native email OTP and Apple sign-in integration code exist. Code does not establish a delivery provider, publisher configuration or verified release-device flow; no automatic email-based account merge |
| Profile/preferences | `docs/architecture/T014-onboarding-profile.md` | Device-local preferences are not automatically server-synchronized or included in export |
| Photo import/editing | `docs/verification/T019-photo-import.md`, `docs/verification/T020-photo-editing.md` | Separate local drafts; system picker/camera; crop and segmentation do not imply AI transmission |
| Private images | `docs/architecture/T011-private-images.md`, `backend/images/pipeline.mjs` | The implementation has owner-bound upload/download capabilities, normalized image variants and a private-storage adapter. The repository does not establish provider legal roles or terms |
| Offline data | `docs/architecture/T012-offline-sync.md` | Local database/outbox and operation IDs; unsynced changes are not in server exports |
| AI | `T015-ai-consent.md`, `docs/architecture/T027-ai-provider.md` | A configurable server adapter enforces an approved recipient/scope and consent before dispatch; withdrawal cancels queued work but cannot recall an already dispatched request. Provider choices/contracts require approval; no production AI acceptance is claimed |
| Export | `docs/architecture/T016-data-export.md` | The authenticated server export builds a synchronized snapshot with eligible garment photos. This implementation does not promise a public download link or complete device backup |
| Deletion | `docs/architecture/T017-account-deletion.md` | The implementation blocks access after accepted deletion and performs durable cleanup. Backup retention and restore behavior require separate operational and owner review |
| Support | `backend/migrations/001_foundation.sql`, `backend/migrations/009_exports.sql` | `support_requests` schema/export coverage is not an inbox, staffed helpdesk or message-delivery implementation |
| StoreKit purchases | `docs/architecture/T049-storekit-purchases.md` | Native StoreKit code and the server entitlement ledger exist; product IDs are absent by default, so an offer must be configured before purchases are available |
| Weather/location | `docs/verification/T042-weather.md`, `backend/weather/met.mjs` | Optional city/approximate-location forecasting is implemented with MET Norway; provider terms, purpose and final disclosure require review |
| Widget and local reminders | `docs/architecture/T045-local-reminders.md`, `docs/architecture/T046-widget-and-wear-shortcut.md` | Local notifications and a privacy-limited App Group widget payload are implemented; the documented design does not require a third-party push provider |
| Diagnostics and analytics | `docs/operations/T053-observability.md` | Consent-gated, bounded first-party telemetry uses the application gateway/database; no third-party analytics provider is selected here |

Paths in this table are repository-relative except T015 in this directory.

## Required owner decisions and evidence

All rows remain **open**. Responsible roles below are not named appointments.
Track decisions here without changing harness-owned planning files. This extends
[T001 D05/D06/D11](../product/T001-specyfikacja-produktu.md), not their approval.

| Gate | Responsible role | Required completion evidence |
| --- | --- | --- |
| G1 Identity/contact | Publisher/controller | Actual legal name, postal address, applicable registration details, monitored support and privacy contacts, DPO contact if applicable; validate ownership without committing private identity documents |
| G2 Processing/legal review | Controller with qualified reviewer | Per-purpose legal basis, rights/request process, complaint authority/contact, applicable consumer terms, age eligibility, contract formation/termination, withdrawal/refund rules and effective date for PL/EN; no blanket liability waiver |
| G3 Recipients | Controller + operator | Actual contracted legal entities, role per processing activity, DPA/version, subprocessors, locations, international-transfer assessment/safeguards, provider training/retention settings and evidence; match T015 disclosure exactly |
| G4 Retention | Controller + operator | Approved duration or precise criterion per data category, configured expiry and deletion evidence for live DB, auth, images/versions, AI copies, support/mail, telemetry/logs, exports, backups/PITR and deletion journal |
| G5 Support | Product owner | Named primary and backup, working mailbox/helpdesk and privacy escalation, actual service hours/response target, access controls and retention; synthetic incoming/reply test including Apple private relay |
| G6 Publication | Authorized publisher | Controlled HTTPS domain, final public PL/EN privacy/terms/support/recipient URLs, effective version/date, approval evidence and archived versions; app and store links verified against final build |

G4 must reconcile T017: deletion markers must survive every restorable copy;
restore replays deletion before exposing services. A 15-minute export access window
is not a promise that all backups expire in 15 minutes. Do not invent a permanent
retention exception for purchases or support: approve the purpose, scope and
period, and implement it before stating it in the policy.

## Publication and release check (authorized operator, outside this sandbox)

1. Resolve G1–G5 and review actual production configuration against every row of
   the traceability table. Remove claims about unavailable features or finish and
   verify their integration. Review current legal/provider requirements with
   authorized access; none were verified online in this task.
2. Finalize matching PL/EN pages with approved identity, contacts, legal sections,
   recipients, retention, effective date and version. Remove internal notes and
   all unresolved decisions. Search for `TODO`, `TBD`, placeholder domains,
   template tokens and draft labels, then manually check completeness: a text
   scan cannot establish factual correctness or legal sufficiency.
3. Publish only approved pages on the controlled HTTPS site. Do not include this
   dossier or operator-only notes. Verify anonymously on iPhone: successful final
   response, valid TLS, no login/paywall, working locale/navigation links, readable
   large text/VoiceOver and no unintended analytics, cookies or third-party assets.
   Inventory hosting access logs and any actual website tracking in the policy.
4. Test the real support and privacy contact end to end with synthetic data. Check
   receipt, assignment, reply and escalation; never commit message contents or
   real customer data. Test account verification without requesting credentials.
5. Verify links from the final app and App Store metadata. Compare consent text,
   export scope, deletion messages, actual retention and published pages. Require
   existing macOS CI and device checks; a local harness pass is not build proof.
6. Record release commit/build, page version, each final URL, UTC verification time,
   approver and safe evidence reference. Recheck on provider, purpose, retention,
   contact or product changes; update consent where disclosure changes require it.

## Acceptance evidence

| T018 criterion | Status | How to close |
| --- | --- | --- |
| Publish Privacy Policy, terms, support and subprocessors matching real flows | **needs verification** | Draft package exists; resolve G1–G6, publish, test public pages and real support, record evidence above |
| Owner supplies controller/contact details; no placeholders in release | **needs verification** | Owner supplies and approves G1, complete all public copy, inspect final pages and release artifact; internal drafts must not ship |

No acceptance criterion is declared met by documentation alone. This repository
change does not enforce a new automatic release gate; the above is a mandatory
manual handoff checklist for the publisher. Hosting, legal approval, production
configuration, real support delivery and macOS/iPhone validation remain external.
