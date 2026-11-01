# ADR-001 — Backend Mojej Szafy (T007)

Data: 2026-11-01. Status: **propozycja warunkowa, bez wdrożenia**.
Zakres: wybór platformy i plan konfiguracji, wyłącznie T007.
Źródła wymagań: [SPEC §5–8](../../SPEC.md),
[T001, decyzje D04/D06/D11](../product/T001-specyfikacja-produktu.md).

## Kontekst i stan dowodów

Repozytorium nie zawiera istniejącego backendu ani dowodów działającego staging.
Potrzebne są PostgreSQL, auth, prywatne zdjęcia i trwałe zadania. Nie ma
udokumentowanej akceptacji T001/D04, uprawnień do kont ani zatwierdzonego budżetu.
W tej sesji zabroniono dostępu do sieci, instalacji zależności, płatnych wywołań,
wdrożeń i zmian kont. Nie utworzono żadnego zasobu ani konta.

Poniższe odnośniki są listą oficjalnych źródeł **do sprawdzenia**, a nie dowodem
ich odczytania lub aktualności na datę ADR. Nie potwierdzono cen, limitów,
dostępności regionów, umów ani retencji. Kryterium „aktualna dokumentacja”
pozostaje otwarte do przeglądu przez osobę z dostępem do sieci.

## Decyzja warunkowa

Proponujemy **Supabase**: zarządzany PostgreSQL, Auth, Storage, kolejkę
PostgreSQL (Supabase Queues/pgmq), Cron i Edge Functions jako wykonawcę workera.
Minimalizuje to liczbę dostawców i pozwala przechowywać zadanie oraz jego stan
przy danych transakcyjnych. Nie wybieramy modelu AI w T007.

Warunek przyjęcia: właściciel zatwierdza D04 po sprawdzeniu źródeł, kosztów,
regionów i umów; test staging potwierdza trwałość kolejki i możliwość wykonania
zadań w aktualnych limitach Edge Functions. Jeżeli limity lub lokalizacja
przetwarzania nie spełniają wymagań, ADR należy zmienić przed wdrożeniem.
Nie zakładamy, że funkcja serwerowa jest stale działającym procesem.

| Element | Docelowy wybór / granica odpowiedzialności |
| --- | --- |
| Baza | Osobny projekt PostgreSQL per środowisko; własność, RLS i constraints w T008 |
| Auth | Supabase Auth; email i Apple z rzeczywistą konfiguracją nadawcy/Apple w T013; bez automatycznego scalania po emailu |
| Zdjęcia | Prywatny bucket `garment-images`; dostęp per właściciel; krótkotrwałe podpisane URL, pipeline w T011 |
| API | Serwerowe operacje transakcyjne i wersjonowane kontrakty w T009; nigdy klucz administracyjny w iOS |
| Kolejka | Trwałe komunikaty w PostgreSQL; payload zawiera ID zadania, bez zdjęć, JWT, podpisanych URL i prywatnych notatek |
| Worker | Cron wywołuje uwierzytelnioną Edge Function, która pobiera ograniczoną partię z kolejki; stan nie zależy od pamięci procesu |
| Urządzenie | Swift/SwiftUI, async/await; lokalna baza i outbox z UUID w T012; wybór backendu nie zmienia natywnego klienta |

Proponowany region danych staging i prod: **Frankfurt, UE (`eu-central-1`)**,
jeżeli dostępny dla wybranego projektu i planu. Osobno sprawdzić lokalizację
wykonania funkcji, backupów, logów, wsparcia i podwykonawców. Region bazy nie
stanowi gwarancji, że całe przetwarzanie pozostaje w UE. Nie obiecujemy takiej
rezydencji danych bez potwierdzonych warunków. Dev ma używać danych syntetycznych;
staging nie otrzymuje kopii produkcyjnych zdjęć ani danych klientów.

## Rozważone warianty

| Wariant | Ocena dla tego repozytorium |
| --- | --- |
| Supabase + kolejka PostgreSQL + funkcje | Preferowany warunkowo: wspólny dostawca bazy, auth i storage; konieczna kontrola limitów czasu i wykonywania workera |
| AWS: RDS, Cognito, S3, SQS i wykonawca | Możliwy technicznie, lecz więcej osobnych usług, polityk IAM i składników rozliczeń; brak istniejącego stosu lub dostępu uzasadniającego ten koszt operacyjny |
| Własny PostgreSQL, auth i storage | Większa odpowiedzialność za aktualizacje, backup i dyżur; brak zespołu operacyjnego i infrastruktury do jej przyjęcia |

To porównanie architektoniczne, nie aktualny benchmark cen lub SLA.
Zmiana wykonawcy workera powinna zachować trwały stan i idempotencję w bazie.

## Trwałość i kontrakt workera

T007 wybiera mechanizm; implementacja tabel należy do T008, a wykonawcy do
T010. Samo `async` w funkcji, pamięć procesu lub wywołanie po odpowiedzi HTTP
nie spełnia trwałości. Docelowy kontrakt:

1. Przyjęcie operacji zapisuje zadanie i komunikat kolejki w jednej transakcji,
   z unikalnym kluczem operacji. Rollback nie pozostawia zadania bez kolejki.
2. Pobranie ustawia visibility timeout oraz lease z identyfikatorem próby.
   Timeout wywołania zewnętrznego jest krótszy niż lease i limit funkcji.
   Odnowienie lease jest kontrolowane; wygasły wykonawca nie zapisuje wyniku
   po przejęciu zadania przez inną próbę (warunkowy zapis z tokenem lease).
3. Wynik i stan końcowy są zapisywane transakcyjnie przed potwierdzeniem
   komunikatu. Ponowne dostarczenie zakończonego zadania tylko potwierdza
   komunikat. Utrata procesu po pobraniu powoduje ponowną widoczność zadania.
4. Retry jest ograniczone, z backoff i jitter. Po przekroczeniu limitu zadanie
   trafia do dead-letter; ręczne wznowienie wymaga audytu. Liczby prób, timeout
   i rozmiar partii ustala T010 po sprawdzeniu limitów i pomiarach.
5. Dostarczenie jest co najmniej jednokrotne. Idempotencja i unikalne
   rezerwacje chronią lokalne skutki. Bez idempotencji dostawcy AI timeout po
   wysłaniu może oznaczać naliczenie opłaty; nie gwarantujemy exactly-once.
   T034 musi rozróżniać taki stan od bezpiecznego ponowienia.
6. Przed wysyłką worker ponownie sprawdza zgodę AI, właściciela, usunięcie
   konta, dostępność danych i kill switch. Odwołana zgoda blokuje zaległą wysyłkę.
7. Awaria Cron opóźnia pracę, nie usuwa kolejki. Alerty obejmują wiek najstarszego
   zadania, brak heartbeat, wygasłe lease i dead-letter. Status w bazie pozwala
   klientowi wrócić po ponownym uruchomieniu aplikacji.

Backup bazy i retencja kolejki wymagają odrębnej konfiguracji i próby restore.
Nie zakładamy, że backup PostgreSQL odtwarza pliki Storage. T055 obejmuje oba
rodzaje danych, ponowne zastosowanie usunięć i pomiar proponowanego RPO 24 h /
RTO 8 h. Te wartości są celami SPEC, nie potwierdzonym SLA.

## Koszt i zgoda właściciela

**Brak aktualnej wyceny i zgody na zakup.** Nie wpisujemy historycznych cen jako
obowiązujących. Przed uruchomieniem właściciel musi otrzymać koszt miesięczny
staging, prod oraz sumę, walutę dostawcy, podatki i datę ważności wyceny.
PLN w szafie nie wyznacza waluty faktury backendu.

Model kosztu miesięcznego: opłata organizacji/planu + compute każdego projektu
+ baza i backup/PITR + storage zdjęć + transfer/egress + auth/MAU + wywołania
i zasoby funkcji + nadawca email + monitoring. Uwzględnić kwoty wliczone w plan,
nadwyżki i compute credits dokładnie raz, zgodnie z aktualnym cennikiem.
AI i pogoda mają osobne budżety w T027/T034/T042; nie są darmowym składnikiem.

| Składnik wyceny | Dane wejściowe wymagane przed akceptacją D04 |
| --- | --- |
| Plan i projekty | Nazwa planu, opłata bazowa, liczba projektów dev/staging/prod, compute per projekt, zasady usypiania i kredytów |
| Baza i backup | GB bazy/indeksów/kolejki/logów, przyrost, okres backupów, dostępność i koszt PITR, koszt restore |
| Zdjęcia | Liczba użytkowników × rzeczy/użytkownika × łączny rozmiar oryginału i pochodnych; brak założenia „jedno zdjęcie = jeden plik” |
| Transfer | Odczyty miniaturek i pełnych zdjęć, eksport, ponowienia uploadu, transfer między usługami, cache hit rate |
| Auth i email | MAU, limity i opłaty auth, liczba wiadomości oraz rzeczywisty nadawca SMTP |
| Worker | Zadania/dzień × próby/zadanie, czas/zasoby wykonania, puste odpytania Cron, limity równoległości |
| Operacje | Monitoring, retencja logów, alerty, podatki i bufor zatwierdzony przez właściciela |

W arkuszu wyceny każdy wiersz musi mieć ilość, jednostkę, stawkę, limit w planie,
koszt nadwyżki oraz źródło z datą. Należy policzyć scenariusz bazowy i wzrostowy,
w tym użytkownika z 1000 rzeczami i 5 latami historii. Bez danych o ruchu nie
podajemy pozornej sumy. Budżet i progi alarmów zatwierdza właściciel (D03/D04).
Alarm kosztu nie jest twardym limitem wydatków; potwierdzić zakres spend cap
dostawcy i osobno limity aplikacji. Nie polegać na darmowym planie jako
dowodzie ciągłego działania staging, backupów lub gotowości produkcyjnej.

## Oficjalne źródła do aktualnej weryfikacji

Każdy wiersz: **niezweryfikowany w tej sesji**. Uprawniona osoba zapisuje datę,
obowiązujące wartości/warunki i bezpieczny identyfikator dowodu. Jeśli adres
zmienił się, należy odszukać bieżącą stronę w oficjalnej dokumentacji.

| Źródło | Co potwierdzić przed akceptacją |
| --- | --- |
| [Supabase Database](https://supabase.com/docs/guides/database/overview) | Wersja PostgreSQL, rozszerzenia, połączenia i ograniczenia planu |
| [Regions](https://supabase.com/docs/guides/platform/regions) | Frankfurt i lokalizacja usług projektu |
| [Pricing](https://supabase.com/pricing) i [Billing](https://supabase.com/docs/guides/platform/billing-on-supabase) | Wszystkie stawki, limity, compute, pauzowanie, spend cap |
| [Auth](https://supabase.com/docs/guides/auth), [Apple](https://supabase.com/docs/guides/auth/social-login/auth-apple), [SMTP](https://supabase.com/docs/guides/auth/auth-smtp) | Dostawcy, redirect allowlist, limity email, wymagania Apple i SMTP |
| [Storage access control](https://supabase.com/docs/guides/storage/security/access-control) | Prywatne buckety, RLS, podpisane URL i uprawnienia usuwania |
| [Queues](https://supabase.com/docs/guides/queues) i [Cron](https://supabase.com/docs/guides/cron) | Trwałość, transakcyjność enqueue, visibility timeout, archiwizacja, retencja i harmonogram |
| [Edge Function limits](https://supabase.com/docs/guides/functions/limits) | Wall-clock, CPU, pamięć, region wykonania i timeout; zgodność z kontraktem workera |
| [Backups](https://supabase.com/docs/guides/platform/backups) | Zakres, retencja, PITR, wyłączenie plików Storage i odtwarzanie |
| [DPA](https://supabase.com/legal/dpa) | Retencja, podwykonawcy, transfery i usuwanie; zatwierdzenie przez właściciela |

## Konsekwencje i odbiór

PostgreSQL ogranicza zależność modelu danych od dostawcy, lecz migracja auth,
storage, funkcji i tokenów sesji pozostaje osobną pracą. RLS nie zastępuje
testów własności, szczególnie dla workera z podwyższonymi uprawnieniami.

[Procedura staging i dowody](../operations/T007-staging.md) opisuje konfigurację
do wykonania po autoryzacji oraz próby odbioru. Oba kryteria T007 pozostają
**needs verification**: ADR istnieje, ale aktualność źródeł/wycena są otwarte;
PostgreSQL, auth, private storage i worker nie zostały uruchomione na staging.
Dokument nie zmienia statusów backlogu i nie zastępuje testu działających usług.
