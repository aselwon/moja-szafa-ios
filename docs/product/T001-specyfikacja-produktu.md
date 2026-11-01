# T001 — Specyfikacja produktu 1.0 do zatwierdzenia

Wersja dokumentu: 1.0, 1 listopada 2026. Źródła: [SPEC.md](../../SPEC.md)
(wersja 2.0) oraz [kanoniczny backlog](../../planning/tasks.json).

Status: przygotowano macierz i rejestr decyzji; brak udokumentowanej akceptacji
właściciela. Dokument nie stanowi potwierdzenia jego zgody, uruchomienia usług
ani gotowości aplikacji. Obejmuje wyłącznie T001. T048 finalizuje ofertę po
pomiarze kosztów w T034; tutaj nie ustalamy cen, trialu ani liczbowych limitów.
W razie rozbieżności źródłem wymagań pozostaje SPEC.md.

## Podstawa wydania

| Obszar | Ustalenie dla 1.0 | Podstawa / status |
| --- | --- | --- |
| Rynek startowy | Polska; rozszerzenie dystrybucji wymaga osobnej decyzji | Wymaganie T001; konfiguracja sklepu w późniejszych zadaniach |
| Języki | Polski (PL) i angielski (EN), w obu planach; interfejs i materiały wydania | SPEC §2, §8; język nie zmienia waluty szafy |
| Waluta szafy | PLN; ceny nullable w całkowitych groszach, brak ceny różny od zera; bez automatycznej konwersji | SPEC §2, §4, §5 |
| Waluta subskrypcji | Cena i waluta lokalizowane przez StoreKit dla sklepu użytkownika | SPEC §2, §7; nie wymuszać PLN ani wpisywać kwot na sztywno |
| Platforma | Natywny iPhone, Swift, SwiftUI, async/await, lokalna baza i synchronizacja | SPEC §5; minimalny iOS i urządzenia do uzgodnienia w D08 |
| Nawigacja | Dzisiaj, Szafa, Zestawy, Statystyki; ustawienia z profilu | SPEC §3 |
| Model oferty | Free oraz Plus; miesięczny i roczny wariant jednej subskrypcji w jednej grupie | Założenie SPEC §2 i T049, do zatwierdzenia w D01/D02 |
| Nazwa | Moja Szafa jest nazwą roboczą | Finalna nazwa i dostępność do potwierdzenia w D10 |

## Kompletna macierz funkcji Free/Plus

Macierz obejmuje funkcje użytkownika ze SPEC §2–3 i T012–T052. „Tak” oznacza
proponowaną dostępność, a nie stan implementacji. Cały szczegółowy podział
wymaga akceptacji D01. Podstawowa ręczna szafa, historia, CPW, zachowanie danych
po wygaśnięciu oraz prawa do eksportu i usunięcia wynikają ze SPEC.

„AI Free” oznacza proponowany ograniczony dostęp próbny do wskazanych operacji;
„AI Plus” — szerszy, również ograniczony dostęp. Przyznanie puli Free, jednostki
rozliczenia, wielkości i okresy odnowienia obu pul są otwarte w D03. Żadne z tych
oznaczeń nie obiecuje nielimitowanego AI ani konkretnej liczby bezpłatnych wywołań.
„Tylko Plus” dotyczy tworzenia nowych danych i korzystania z narzędzia; odczyt,
eksport i usunięcie wcześniej zapisanych danych pozostają dostępne po utracie Plus.

| Funkcja i zakres | Free — propozycja | Plus — propozycja | Zadania |
| --- | --- | --- | --- |
| Onboarding z przykładem i pominięciem, opcjonalny profil preferencji | Tak | Tak | T014 |
| Sign in with Apple i email, sesje, private relay, wylogowanie | Tak | Tak | T013 |
| Ustawienia profilu, języka, miasta, zgód AI/analityki, pomocy i polityk | Tak | Tak | T014, T015, T018, T042 |
| Import pojedynczy, wielu zdjęć i aparat; osobne drafty i statusy | Tak | Tak | T019 |
| Kadrowanie, usuwanie tła, oryginał i podgląd; zapis bez segmentacji przy błędzie | Tak | Tak | T020 |
| Ręczny formularz ubrania, cena, data, marka oraz korekta sugestii | Tak | Tak | T021 |
| Rozpoznawanie AI kategorii, kolorów, wzoru, sezonu i formalności | AI Free; zawsze ręczny zapis | AI Plus; zawsze ręczny zapis | T028 |
| Szafa: miniatury, wyszukiwanie, filtry, sortowanie, szczegóły i historia | Tak | Tak | T022 |
| Dostępność, pranie, niedostępność i niezależna archiwizacja | Tak | Tak | T023 |
| Trwałe usuwanie ubrania, zdjęć i relacji z wyjaśnieniem wpływu | Tak | Tak | T024 |
| Ostrzeganie o potencjalnych duplikatach bez automatycznego scalania | Tak | Tak | T025 |
| Synchronizacja między urządzeniami i offline: ubrania, noszenia, outbox, konflikty | Tak | Tak | T012 |
| Ręczne zestawy: kreator, kolaż, zapis, nazwa, edycja, ulubione | Tak | Tak | T026 |
| Dzisiaj: aktualny plan, zapis noszenia, dostępne propozycje | Tak; nowe propozycje według AI Free | Tak; nowe propozycje według AI Plus | T030, T031, T035, T041 |
| Generowanie 1–10 propozycji (domyślnie 3), okazja, pogoda/temperatura, uwagi, przypięta rzecz | AI Free | AI Plus | T029, T030 |
| Karta propozycji: kolaż realnych rzeczy, uzasadnienie, zapis i „Noszę dzisiaj” | Tak dla dostępnych wyników | Tak dla dostępnych wyników | T031 |
| Zamiana elementu z zachowaniem reszty zestawu | Ręczna: tak; AI: AI Free | Ręczna: tak; AI: AI Plus | T031 |
| Preferencje, wykluczenia, feedback lubię/nie lubię i reset personalizacji | Tak; nie przyznaje dodatkowej puli AI | Tak; nie przyznaje dodatkowej puli AI | T032 |
| Dziennik: zapis, edycja i cofnięcie noszenia; kalendarz historii | Tak | Tak | T035, T038 |
| CPW lifetime, brak ceny/brak noszeń, estymacja wcześniejszych noszeń z oznaczeniem | Tak | Tak | T036, T037 |
| Statystyki: wartość znanych cen, braki, rankingi CPW/noszeń, nigdy nienoszone i 90 dni | Tak | Tak | T039 |
| Lista rzeczy do przeglądu: zachowaj, archiwizuj, przypomnij zestaw | Tak; nowe generowanie według AI Free | Tak; nowe generowanie według AI Plus | T040 |
| Ręczny planer przyszłych dni, przenoszenie i usuwanie planów | Tak | Tak | T041 |
| Pogoda, ręczne miasto, opcjonalna lokalizacja i ręczna temperatura jako fallback | Tak; użycie AI według AI Free | Tak; użycie AI według AI Plus | T042 |
| Wyjazd: daty, miejsce, okazje, ograniczona lista rzeczy, plan zestawów, checklista | Tylko odczyt/eksport/usunięcie wcześniej zapisanych danych | Tak; operacje AI według AI Plus | T043 |
| Sprawdzenie zakupu: tymczasowy kandydat, dopasowania do szafy | Tylko odczyt/eksport/usunięcie wcześniej zapisanych danych | Tak; operacje AI według AI Plus | T044 |
| Potwierdzenie zakupu i ręczne dodanie kupionej rzeczy do szafy | Tak, także z zachowanego kandydata | Tak | T021, T044 |
| Powiadomienia lokalne opt-in o planie/noszeniu, quiet hours, deep link | Tak | Tak | T045 |
| Widget planu/dzisiaj i skrót z potwierdzeniem noszenia | Tak | Tak | T046 |
| Eksport wybranego kolażu przez share sheet | Tak | Tak | T047 |
| Prywatny eksport danych JSON i zdjęć, w tym historii, planów i cen | Tak | Tak | T016 |
| Usunięcie konta i danych; niezależne od aktywnej subskrypcji | Tak | Tak | T017 |
| Oferta, zakup, restore, stan uprawnień i zarządzanie subskrypcją | Tak; zakup/restore może przywrócić Plus | Tak | T048, T049, T050, T051, T052 |

Wspólne dla wszystkich wierszy: PL/EN, dark mode, VoiceOver, Dynamic Type,
Reduce Motion, stany empty/loading/error/offline i ścieżka powrotu. Offline
nie oznacza wykonywania zewnętrznego AI lub pobierania świeżej pogody bez sieci.
Prywatność zdjęć, izolacja danych, brak EXIF w uploadzie, bezpieczna sesja,
wyczyszczenie cache konta i widgetu po wylogowaniu nie są dodatkiem płatnym.
Monitoring, backup, panel operacyjny i testy jakości są obowiązkami utrzymania
całego produktu, a nie funkcjami sprzedawanymi jako Plus (SPEC §5–8).

## Zachowanie przy ograniczeniach i utracie Plus

- Po wygaśnięciu Plus użytkownik zachowuje odczyt i eksport danych oraz ręczne
  dodawanie/edycję szafy, zestawów, noszeń, CPW i podstawowego planera.
  Istniejących danych nie wolno usuwać ani ukrywać za paywallem. Nowe operacje
  wyłącznie Plus wymagają odzyskania uprawnienia; dostęp AI wraca do zatwierdzonej
  polityki Free, bez automatycznej obietnicy nowej puli próbnej.
- Wyczerpanie puli AI, awaria, timeout, brak sieci lub kill switch: czytelny stan,
  ręczny formularz ubrania/kreator/zamiana oraz dostęp do wcześniejszych zapisów.
  Niepowodzenie segmentacji pozwala zachować zdjęcie bez usuniętego tła.
  Rezerwacja nieudanej operacji AI podlega zwolnieniu zgodnie z T034.
- Odmowa lub cofnięcie zgody AI blokuje nowe wysyłki, również niewysłaną kolejkę,
  niezależnie od opłaconego planu. Odmowa lokalizacji ma alternatywę ręczną,
  odmowa powiadomień nie ogranicza funkcji aplikacji.
- Paywall można zamknąć. Restore i zarządzanie zakupami pozostają dostępne.
  Pending, grace period, billing retry, refund/revoke i wygaśnięcie muszą być
  obsłużone w T049–T052 na podstawie zweryfikowanych uprawnień serwerowych.
- Usunięcie konta nie wymaga wcześniejszego anulowania subskrypcji. Aplikacja
  wyjaśnia, że usunięcie konta samo nie anuluje płatności Apple, i udostępnia
  zarządzanie subskrypcją bez blokowania żądania usunięcia.

Żaden wariant oferty nie zmienia reguł SPEC §4: jedno noszenie rzeczy na lokalny
dzień, historyczna lista ubrań, plany bez zwiększania CPW, cena w groszach,
oznaczone estymacje. AI nie oblicza CPW, nie wymyśla produktów ani ceny, marki
i daty zakupu. Kandydat zakupu nie jest posiadaną rzeczą przed potwierdzeniem.

## Rejestr decyzji właściciela

Właścicielem każdej poniższej decyzji jest **właściciel produktu / uprawniony
wydawca**. To rola odpowiedzialna, nie fikcyjnie przypisana osoba; jej tożsamość
nie została dostarczona. Każda decyzja ma status **otwarta — brak potwierdzenia**.
Kolumna blokad określa, jakiego etapu zadania nie można uznać za zakończony;
nie zmienia zależności ani statusów harnessu. Dalsze zależności wynikają z JSON.

| ID | Decyzja i wymagany dowód | Właściciel | Blokowane zadania / etap |
| --- | --- | --- | --- |
| D01 | Zatwierdzić tę wersję zakresu, Polskę, PL/EN, PLN i szczegółowy podział Free/Plus, w tym narzędzia wspólne oraz wyjazdy/zakupy Plus. Dowód: akceptacja wersji dokumentu z datą i identyfikacją zatwierdzającego | Właściciel produktu | T001: formalne zatwierdzenie; T002: finalny zakres projektu; T048: finalna oferta |
| D02 | Ustalić ceny miesięczną/roczną, trial (w tym możliwość braku trialu) i warunki po pomiarze kosztów. Dowód: zatwierdzona oferta i później rzeczywista konfiguracja StoreKit; obecnie brak kwot i okresu trialu | Właściciel produktu | T048: decyzja handlowa; T049: konfiguracja produktów; T051: finalny paywall |
| D03 | Zatwierdzić istnienie puli próbnej Free, limity Free/Plus per operacja, jednostkę i okres odnowienia, zasady po downgrade oraz budżet globalny i progi alarmów. Rozstrzygnąć ewentualne limity szafy/storage bez blokowania praw do danych. Dowód: polityka oparta na pomiarach, bez obietnicy nielimitowanego AI | Właściciel produktu | T034: produkcyjne wartości limitów; T048: finalna oferta; T050: egzekwowanie finalnych uprawnień; T053: progi alarmów |
| D04 | Zapewnić uprawniony dostęp i budżet na backend, storage, worker i pogodę; zatwierdzić region, koszty i retencję po ADR. Dowód: akceptacja ADR i dostęp przekazany bezpiecznie poza repo | Właściciel produktu | T007: uruchomienie staging; T042: rzeczywista usługa pogody; T055: strategia backup/restore |
| D05 | Zatwierdzić dostawcę/model AI, koszt i warunki przetwarzania/retencji po sprawdzeniu dokumentacji i ewaluacji; zapewnić legalny zbiór oceny. Dowód: zaakceptowany wybór i raport, zgodny z treścią zgody | Właściciel produktu | T015: finalna zgoda; T027: realna integracja; T033: legalny zbiór i ocena; T018: opis odbiorców danych |
| D06 | Dostarczyć rzeczywistą tożsamość administratora/wydawcy, dane kontaktowe, zatwierdzone polityki, retencję oraz docelowe privacy/support URL. Dowód: zweryfikowane dane i później dostępne strony; obecnie brak danych prawnych i adresów | Właściciel produktu / wydawca | T018: publikacja polityk i wsparcia; T017: zgodność retencji usunięć; T063: finalne URL; T064: dane formularzy |
| D07 | Zapewnić Apple Developer/App Store Connect, role, bundle ID, podpisywanie i wymagane umowy/podatki. Dowód: działający uprawniony dostęp i podpisany build, bez sekretów w repo | Uprawniony wydawca | T061: konto i podpisywanie; T006: podpisywanie CI; T049: konfiguracja IAP; T062: dystrybucja bety |
| D08 | Uzgodnić minimalny iOS, macOS/Xcode, fizyczne urządzenia i profil sieci do pomiarów. Dowód: macierz wsparcia i dostępny sprzęt; cele SPEC nie stają się wynikami przez akceptację | Właściciel produktu | T005: docelowa platforma; T057, T058: testy urządzeń; T059: pomiary wydajności |
| D09 | Zapewnić testerów prototypu i bety oraz osoby oceniające użyteczność AI. Dowód: rzeczywiste sesje/raporty według T004, T033 i T062; nie wpisywać fikcyjnych uczestników | Właściciel produktu | T004: co najmniej 5 sesji; T033: oceny zbioru; T062: minimum 7 dni i 10 zaproszonych testerów z raportem aktywności |
| D10 | Potwierdzić finalną nazwę po sprawdzeniu dostępności oraz zatwierdzić ikonę i materiały PL/EN. Dowód: akceptacja rzeczywistych materiałów i zrzutów buildu | Właściciel produktu | T063: finalne materiały sklepu |
| D11 | Wyznaczyć osoby do supportu, alarmów, prywatności, backupów, hotfixów i dyżuru pierwszych 72 h; zatwierdzić cele jakości/odtwarzania do weryfikacji pomiarami. Dowód: rzeczywiste przypisania, runbook i raporty, bez obniżania bramek dla zaliczenia | Właściciel produktu | T018: obsada wsparcia; T053, T054: odpowiedzialność operacyjna; T055, T059, T062: ocena pomiarów; T069, T070: dyżur i przekazanie |
| D12 | Uprawniony wydawca podejmuje decyzję o submission i publikacji dopiero po dowodach jakości i akceptacji Apple. Dowód: zweryfikowany build, rzeczywisty status review i publiczna wersja | Uprawniony wydawca | T065: gotowość RC; T066: wysyłka; T068: publikacja |

Otwarte decyzje oznaczają brak danych lub akceptacji, a nie odmowę właściciela.
W T001 nie wykonano operacji na kontach, zakupów usług, importu do Lineara,
konfiguracji IAP ani publikacji. W rejestrze nie zapisujemy sekretów, danych
podatkowych ani prywatnych dokumentów; dopuszczalny jest bezpieczny identyfikator
dowodu przekazanego uprawnionym osobom.

## Granice i sposób zatwierdzenia

Poza 1.0 pozostają: Android, social feed, publiczne profile, marketplace,
afiliacja, fotorealistyczna przymierzalnia, analiza ciała, całodzienne
rozpoznawanie z kamery, skanowanie paragonów i automatyczna konwersja walut.

Właściciel powinien wskazać wersję dokumentu, zaakceptowane decyzje (lub korekty),
datę oraz dowód akceptacji. D01 zatwierdza bazowy zakres; D02–D12 mogą pozostać
otwarte do wskazanych etapów i nie są domyślnie zatwierdzone wraz z D01.
Zmiana oferty wymaga aktualizacji macierzy i sprawdzenia wpływu na powiązane
zadania; statusy backlogu nadal obsługuje harness.

Na dziś nie ma dowodu formalnego zatwierdzenia D01. Dokumentacja kryteriów
T001 jest przygotowana, ale tytułu „Zatwierdź specyfikację” nie należy traktować
jako potwierdzenia akceptacji przez właściciela. Gotowość release i faktyczna
publikacja to oddzielne etapy; obowiązują wszystkie bramki jakości SPEC §8.
