# Recipients and subprocessors / Odbiorcy i podwykonawcy

Version 0.1, 2026-11-03. **Internal draft; no contracted provider list verified.**
A provider may act as a processor, separate controller or have different roles
for different activities. Do not describe every recipient as a subprocessor.
The controller must approve legal roles and actual entities before publication.

## Inventory for owner review

| Recipient/service | Actual evidence and status | Data/purpose to verify | Missing evidence |
| --- | --- | --- | --- |
| Backend/auth/private storage/worker | Supabase is a conditional proposal in ADR-001; repository SQL/adapters do not prove a deployed project | Account identifiers/email, wardrobe records/photos, consent, queued jobs, exports and deletion state for service delivery | Contracted entity, DPA, actual region, function/log/backup locations, retention, subprocessors and transfer safeguards |
| Apple authentication | Apple sign-in client/gateway contracts; no device/production verification | Linked subject, identity proof and permitted account information, private relay; login and grant revocation | Actual publisher configuration and applicable Apple role/terms, transfer/retention disclosures |
| Apple purchases | Product requirement; not evidence of activated StoreKit integration | Transactions/entitlement status when implemented; do not claim the app receives card details | Verified integration, actual fields, roles, retention and approved purchase terms |
| External AI | Generic server adapter with no default vendor/model; dispatch blocked without approved recipient and consent | Normalized image for analysis; selected metadata/context for suggestions; operational usage metadata | Legal entity, models, endpoints, DPA, processing locations, training prohibition, actual retention/deletion, onward recipients and transfer safeguards |
| Transactional email | Email auth contract; no approved SMTP operator | Destination email and authentication/delivery messages | Real sender/provider, roles, metadata retention, relay delivery and subprocessors |
| Support/mail/helpdesk | Schema exists; no channel provisioned | Contact details, reports and minimal diagnostics | Provider/entity, staffed owner, access controls, retention including attachments/backups |
| Website hosting/DNS/CDN | No policy site or host provisioned | Page requests and any access/security logs; no analytics assumed | Public host/entity, actual logs/cookies/assets, locations and retention |
| Weather/location | Future feature | Selected city or optional location if enabled | Provider, transmitted precision, purpose, consent/permission behavior and retention |
| Monitoring/analytics | Safe telemetry contracts; no verified external service | Necessary error/usage identifiers and metrics; no raw private inputs in logs | Vendor or self-hosted choice, real payloads, opt-in behavior where applicable and retention |

Sources: [ADR-001](../architecture/ADR-001-backend.md),
[T013](../architecture/T013-authentication.md), [T015](T015-ai-consent.md),
[T016](../architecture/T016-data-export.md),
[T017](../architecture/T017-account-deletion.md),
[T027](../architecture/T027-ai-provider.md), SPEC §5–8.
No current provider terms or legal requirements were retrieved in this offline task.

## PL — public introduction for review

Lista odbiorców opisuje, komu przekazujemy dane, w jakim celu i zakresie, gdzie
są przetwarzane oraz jak długo są przechowywane. Rola odbiorcy zależy od usługi.
Przed zewnętrzną analizą AI aplikacja pokazuje konkretnego odbiorcę i zakres danych
oraz prosi o zgodę. Sam region bazy w UE nie oznacza, że wszystkie usługi,
wsparcie i kopie zapasowe przetwarzają dane wyłącznie w UE.

## EN — public introduction for review

The recipient list explains who receives data, for what purpose and scope,
where processing occurs and how long data is retained. A recipient's role depends
on the service. Before external AI analysis, the app identifies the recipient
and data scope and requests consent. An EU database region alone does not mean
all services, support and backups process data exclusively in the EU.

## Final public register requirements

Replace this internal inventory with verified PL/EN entries for enabled services:
legal entity and service, role, data categories, purpose, countries/regions,
retention or precise criterion, applicable transfer safeguards and current policy/
subprocessor references with review date. Identify any onward-processor list
maintained by the contracted provider. Keep disabled/future candidates out of
the public list of actual recipients. Do not name an AI vendor merely because
its protocol is supported. Publish actual entities only after contractual and
configuration review under [G3/G4](T018-publication.md).

The no-training requirement must be supported by contract and configured service
settings; it is not established by calling an API. Changes to recipient or scope
must update the public register and T015 disclosure before dispatch. That mechanism
invalidates prior grants when the disclosure changes; test queued-job refusal.
