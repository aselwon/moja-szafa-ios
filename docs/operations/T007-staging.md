# T007 — Konfiguracja i odbiór staging

Powiązana decyzja: [ADR-001](../architecture/ADR-001-backend.md).
Status 2026-11-01: **nie wykonano konfiguracji ani testów usług**.
To procedura dla uprawnionego operatora po zatwierdzeniu D04, nie zapis wdrożenia.

## Blokady i odpowiedzialność

| Blokada | Odpowiedzialna rola | Warunek odblokowania |
| --- | --- | --- |
| Brak potwierdzenia T001/D04 | Właściciel produktu | Akceptacja zakresu, ADR, regionu, wyceny i budżetu z datą |
| Brak sieci i zgody na operacje usługowe w tej sesji | Uprawniony operator | Osobna autoryzowana sesja z siecią; przegląd aktualnej dokumentacji |
| Brak konta, projektu staging i uprawnień | Właściciel konta backendu | Przydział minimalnych ról przez bezpieczny kanał, MFA, zatwierdzony plan |
| Brak schematu i implementacji workera | Wykonawcy T008/T010 | Kod i migracje przed testami pełnych zadań aplikacji; w T007 można odebrać wyłącznie izolowany test infrastruktury |
| Brak danych nadawcy email i konfiguracji Apple | Właściciel produktu/wydawca | Zweryfikowany nadawca SMTP i konfiguracja Apple; pełny odbiór na urządzeniu w T013 |

Nie przekazywać haseł, kluczy, JWT, prywatnych URL ani danych testerów w repo,
opisie PR czy logach. Nie wklejać wyników panelu zawierających takie dane.

## Docelowa konfiguracja do zastosowania po autoryzacji

1. Sprawdzić źródła ADR i zapisać aktualną wycenę. Jeśli mechanizmy kolejki,
   region lub limity wykonania nie spełniają kontraktu, zaktualizować decyzję.
2. W organizacji właściciela utworzyć osobny projekt `moja-szafa-staging`
   w zatwierdzonym regionie. Dev i prod mają odrębne projekty, dane, klucze,
   buckety i redirect allowlist. Nie kopiować produkcyjnych danych do staging.
3. Zapisać niesekretne identyfikatory projektu, region, wersję PostgreSQL,
   plan i wersje rozszerzeń w protokole odbioru. Połączenia wyłącznie TLS;
   sekrety administracyjne przechowywać w zarządzanym magazynie serwerowym.
   Dostęp operatorów przez imienne role i MFA, bez współdzielonego konta.
4. Skonfigurować auth: potwierdzanie emaila, dokładną allowlistę powrotów
   staging bez wildcardów produkcyjnych, limity i rzeczywistego nadawcę SMTP.
   Nie wymyślać bundle ID ani domen; otrzymać je od właściciela. Apple pozostaje
   wyłączone do posiadania prawidłowej konfiguracji. Sekrety Apple tylko po
   stronie serwera. Zalogowanie konta testowego nie dowodzi całego T013.
5. Utworzyć prywatny bucket `garment-images`. Bez publicznych odczytów i list.
   Polityki muszą sprawdzać właściciela przy odczycie, zapisie i usuwaniu;
   prefiks ścieżki sam nie jest autoryzacją. Domyślnie odmowa, zanim istnieją
   sprawdzone polityki. Nie udostępniać tabel testowych ani kolejek przez API.
   Produkcyjne constraints i RLS należą do T008, pipeline do T011.
6. Włączyć zatwierdzone rozszerzenia kolejki i harmonogramu. Utworzyć izolowaną
   kolejkę testową i minimalnego wykonawcę bez płatnych API: wejście z operation
   UUID, wynik deterministyczny, trwały status i kontrolowana awaria. Cron ma
   wywoływać chroniony endpoint; nie wyłączać uwierzytelniania dla wygody.
   Dane uwierzytelniające harmonogramu przechowywać w magazynie sekretów.
   Pełny worker i polityki retry aplikacji pozostają zakresem T010.
7. Włączyć dostępne backupy, alarmy kosztów i metryki kolejki; udokumentować
   retencję i zakres odtwarzania. Wyznaczyć rzeczywistego odbiorcę alarmów (D11).
   Nie oznaczać RPO/RTO jako osiągniętych bez ćwiczenia T055.
8. Konfigurację endpointów klienta przekazać do T006/T009. iOS nie może
   otrzymać hasła bazy, service-role ani sekretu workera. Release ma odrzucać
   konfigurację staging; nie używać mocka jako domyślnego backendu release.

Nie dołączono plików deploymentu z fikcyjnymi project ID ani pozornej
konfiguracji wdrożonej usługi. Po wyborze rzeczywistego projektu operator
powinien zachować zanonimizowany eksport konfiguracji i rewizję wdrożonego
wykonawcy, aby wynik był odtwarzalny.

## Macierz prób odbioru

Wykonać na autoryzowanym staging, z syntetycznymi danymi i dwoma izolowanymi
kontami A/B. Każda próba wymaga daty, operatora, rewizji konfiguracji/kodu,
oczekiwanego i rzeczywistego wyniku oraz odnośnika do zanonimizowanego dowodu.
Wszystkie poniższe próby mają obecnie status **not run**.

| ID | Próba | Wymagany wynik |
| --- | --- | --- |
| S01 | Połączenie TLS do PostgreSQL, zapis i odczyt syntetycznej wartości z nowego połączenia, rollback osobnej transakcji | Commit zachowany, rollback niewidoczny; zapisany region i wersja |
| S02 | Email: rejestracja, potwierdzenie i logowanie A, refresh; odczyt chronionego zasobu bez tokenu i z wygasłym tokenem | Rzeczywista sesja działa; brak autoryzacji jest odrzucony; niedozwolony redirect odrzucony |
| S03 | A uploaduje syntetyczny obraz; B i anonimowy klient próbują odczytu, listowania, nadpisania, usunięcia i uzyskania signed URL obiektu A | Tylko A wykonuje dozwolone operacje; publiczny URL nie ujawnia obrazu |
| S04 | A otrzymuje krótkotrwały signed URL, nowy odczyt przed i po expiry bez cache | Działa przed, odrzucany po wygaśnięciu; URL nie trafia do raportu/logów. URL przed wygaśnięciem jest bearer capability, nie obietnicą ponownej autoryzacji odbiorcy |
| S05 | Enqueue UUID, zakończenie procesu po pobraniu, uruchomienie nowej instancji po visibility timeout | Ten sam job odzyskany z bazy, trwały wynik i status, brak zagubienia |
| S06 | Awaria po zapisie wyniku, przed ack; ponowne dostarczenie; dwóch wykonawców i spóźniony zapis starego lease | Jeden skutek, stary lease odrzucony, ponowne dostarczenie bez powtórzenia skutku |
| S07 | Wyłączony harmonogram, potem przywrócenie; zadanie stale kończące się błędem | Kolejka przetrwała przerwę, alert działa; ograniczone retry kończy się dead-letter |
| S08 | Cofnięcie zgody / tombstone konta przed wysyłką w testowym wykonawcy | Zero wysyłek zewnętrznych dla zablokowanego zadania; pełny test domenowy ponowić w T010/T015/T017 |
| S09 | Wywołanie endpointu workera bez autoryzacji; próba dostępu klienta do kolejki | Odmowa; brak eskalacji uprawnień i sekretów w odpowiedzi/logach |
| S10 | Porównanie identyfikatorów projektów i konfiguracji dev/staging/prod; kontrola billing/backup | Rozdzielone środowiska; zatwierdzone limity i odbiorcy alarmów, bez twierdzenia o przetestowanym restore |

Test izolowanej kolejki potwierdza wyłącznie infrastrukturę, nie gotowość AI,
eksportu, usuwania czy naliczania limitów. W żadnej próbie T007 nie potrzeba
płatnego wywołania AI; użyć deterministycznej operacji syntetycznej.

## Protokół zamknięcia T007

Dołączyć zatwierdzenie ADR/D04, daty sprawdzenia źródeł, wycenę staging/prod,
identyfikację środowiska i rewizji, rzeczywiste wyniki S01–S10 z ograniczeniami
oraz listę nadal otwartych zależności. Nie zamieniać `not run` na sukces na
podstawie samego istnienia dokumentacji czy zielonego harness-check.

Obecny wynik: przygotowano ADR i procedurę; aktualna dokumentacja i kosztorys
**needs verification**, działający PostgreSQL/auth/private storage/worker na
staging **needs verification**. Brak dostępu i zakaz wdrożeń uniemożliwiają
domknięcie odbioru w tej sesji. Statusami backlogu zarządza wyłącznie harness.
