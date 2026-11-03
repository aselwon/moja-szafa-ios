# Support / Pomoc — internal draft and operating handoff

Version 0.1, 2026-11-03. **Not published; no functioning support channel claimed.**
A `support_requests` table alone does not deliver messages. No mailbox, helpdesk,
public support URL, named responder or response-time commitment was supplied.
The owner must resolve [G1/G4/G5/G6](T018-publication.md). Publish only the reviewed
public sections with real contact details, hours and approved response target.

## PL — public copy for review

Potrzebujesz pomocy z Moja Szafa? Opisz, co próbujesz zrobić, co się wydarzyło,
wersję aplikacji i iOS oraz przybliżony czas problemu. Jeśli aplikacja pokazuje
identyfikator żądania, dołącz go. Zrzut ekranu jest opcjonalny: usuń z niego dane
prywatne i niepotrzebne zdjęcia. Nie wysyłaj haseł, kodów logowania, tokenów,
danych karty ani całego eksportu szafy.

Przy braku sieci ponów operację po odzyskaniu połączenia. Nie usuwaj aplikacji,
aby rozwiązać problem synchronizacji — niewysłane lokalne dane mogą zostać
utracone. Brak AI nie blokuje ręcznej pracy. Zgodą AI zarządzasz w profilu,
w ustawieniach prywatności i AI.

Eksport i usunięcie konta znajdziesz w profilu. Eksport obejmuje dane
zsynchronizowane, a pobranie wymaga zalogowania i jest dostępne przez 15 minut.
Usunięcie wymaga potwierdzenia tożsamości i nie anuluje subskrypcji Apple.
Zakupami zarządzaj w ustawieniach subskrypcji Apple. Jeśli nie możesz zalogować
się lub użyć tych funkcji, zgłoś problem kanałem wsparcia; weryfikacja konta
nie wymaga podania hasła ani kodu logowania pracownikowi wsparcia.

## EN — public copy for review

Need help with Moja Szafa? Describe what you were trying to do, what happened,
your app and iOS versions and the approximate time. Include a request identifier
if the app displays one. Screenshots are optional: remove private information
and unnecessary photos. Never send passwords, login codes, tokens, card details
or your entire wardrobe export.

If offline, retry after connectivity returns. Do not uninstall the app to fix
synchronization: unsent local data could be lost. AI unavailability does not
block manual work. Manage AI consent in Profile's Privacy and AI settings.

Find data export and account deletion in Profile. Export covers synchronized
data; download requires authentication and is available for 15 minutes. Deletion
requires identity confirmation and does not cancel an Apple subscription.
Manage purchases in Apple's subscription settings. If you cannot sign in or use
these features, contact support; account verification does not require giving
a support agent your password or login code.

## Internal operating procedure — do not publish

1. Owner provisions a monitored channel and appoints primary/backup responders
   and a privacy escalation owner. Approve hours, realistic response target,
   mailbox/helpdesk provider, access roles with MFA, and retention/deletion rules.
   Add the real contact to both language pages; avoid an unmonitored `mailto` link.
2. Acknowledge receipt with a ticket reference and approved response expectation.
   Classify: access/authentication, sync/photos, AI consent, purchase, data rights,
   deletion/export or security. Do not promise resolution before investigation.
3. Collect only necessary diagnostics. Never ask for credentials, full archives
   or default access to wardrobe photos. Redact unnecessary attachments and
   remove accidentally received secrets through the approved incident process.
4. Verify identity through the authenticated app/gateway process before account
   actions. Email resemblance, private-relay address or ticket possession is not
   sufficient authorization. Account recovery requires a vetted identity flow;
   do not manually merge accounts or bypass deletion verification.
5. Escalate privacy/security reports promptly to appointed owners; assess actual
   obligations and deadlines with the responsible reviewer. Escalate stalled
   deletion/export to the operator; an accepted job is not completed erasure.
   Use safe request/job IDs in restricted diagnostics, not raw photos or tokens.
6. Communicate the result in the user's language and confirm the next step.
   Apply approved retention to tickets, attachments, mail copies and helpdesk
   backups. Explain and approve any necessary retention exception; no indefinite
   blanket retention. Restrict and audit operator access.
7. Before release, send synthetic messages in PL/EN, test replies including
   Apple private relay, absent-primary coverage and privacy escalation. Record
   only safe evidence references, dates and results outside customer logs.
