# Recipients and subprocessors / Odbiorcy i podwykonawcy

Version 0.2. **Internal draft; no contracted provider list verified.**
A provider may act as a processor, separate controller or have different roles
for different activities. Do not describe every recipient as a subprocessor.
The rows below separate repository implementation facts from unresolved contract
and legal-role decisions. The controller must approve actual entities before
publication.

## Inventory for owner review

| Recipient/service | Actual evidence and status | Data/purpose to verify | Missing evidence |
| --- | --- | --- | --- |
| Backend, identity and private images | The repository backend targets Neon/Postgres rather than the earlier Supabase proposal in ADR-001. It includes a gateway and a private-image storage adapter. This describes implementation scope, not provider legal roles or contracts. | Account identifiers/email, wardrobe records/photos, consent, queued jobs, exports and deletion state for service delivery | Contracted legal entities and roles, DPA, actual regions, gateway/log/backup locations, retention, subprocessors and transfer safeguards |
| Email authentication and delivery | Native email OTP and managed-auth integration code exist; this repository does not establish the outbound email operator or sender terms. | Destination email and authentication/delivery metadata | Selected delivery provider/sender, legal role, sender configuration, retention, relay behavior and subprocessors |
| Apple authentication | Native Apple sign-in code and gateway contracts exist; code alone does not establish publisher configuration or a verified device flow | Linked subject, identity proof and permitted account information, including a private-relay address if used | Actual publisher configuration, applicable Apple role/terms, transfer and retention disclosures, and release verification |
| Apple purchases | Native StoreKit mechanics and a server entitlement ledger are implemented. Product IDs are absent by default, so purchases require publisher offer configuration. | Verified transaction and entitlement status when configured; the app does not receive card details | App Store Connect products/group, prices/trial, publisher agreements, notification registration, actual fields/roles/retention and approved purchase terms |
| External AI | The server has a configurable AI adapter and consent/recipient checks. Provider/model choices and contracts still require approval; this repository does not establish production acceptance. Image analysis is a separate capability and does not follow from text-AI support. | If approved and enabled: selected wardrobe metadata/context for text suggestions; normalized image only for an approved image operation; limited usage metadata | Provider legal entity/role, model and endpoint, DPA, processing locations, training and retention terms, deletion behavior, onward recipients and transfer safeguards |
| Weather/location | Optional forecast is implemented through the authenticated gateway and MET Norway Locationforecast. The client supports explicit city selection or user-triggered approximate location. | Location input and forecast context | Provider terms/role, processing locations, retention, attribution/license and location-purpose review |
| Support/mail/helpdesk | The `support_requests` schema and export do not provide message delivery or a helpdesk implementation | Contact details, reports and minimal diagnostics | Provider/entity, staffed owner, access controls, retention including attachments/backups |
| Website hosting/DNS/CDN | The repository has no policy/support-site publishing integration | Page requests and any access/security logs; no analytics assumed | Public host/entity, actual logs/cookies/assets, locations and retention |
| Monitoring/analytics | Consent-gated, bounded first-party diagnostics/analytics are implemented; no separate third-party analytics provider is selected in this dossier | Allowlisted diagnostic outcomes, timings and aggregate activation counts; no photos, garment names, email addresses, tokens or raw request bodies | Confirm release configuration, file/log handling, retention and any future provider before publication |

Sources: [ADR-001](../architecture/ADR-001-backend.md),
[T013](../architecture/T013-authentication.md), [T015](T015-ai-consent.md),
[T016](../architecture/T016-data-export.md),
[T017](../architecture/T017-account-deletion.md),
[T027](../architecture/T027-ai-provider.md),
[T042](../verification/T042-weather.md),
[T049](../architecture/T049-storekit-purchases.md), SPEC §5–8. Provider terms,
legal roles and applicable requirements still need authorized review.

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
