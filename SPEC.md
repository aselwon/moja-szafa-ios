BRIEF PRODUKTOWY I TECHNICZNY — CYFROWA SZAFA NA iOS
Wersja 2.0 — pełny produkt 1.0 do publikacji w App Store
Nazwa robocza: Moja Szafa. Data specyfikacji: 1 listopada 2026.

1. CEL I DEFINICJA GOTOWOŚCI

Zbuduj, przetestuj i przygotuj do publicznej dystrybucji natywną aplikację iPhone. Użytkownik fotografuje ubrania, otrzymuje użyteczne stylizacje z własnej szafy, planuje je, rejestruje noszenie i obserwuje cost per wear. To pełne wydanie konsumenckie 1.0 z prawdziwymi integracjami, synchronizacją, obsługą klienta i utrzymaniem. Makieta, demonstracja, TestFlight i sam upload do Apple nie oznaczają ukończenia.

Zakres tego dokumentu obejmuje publikację i pierwsze 72 godziny obsługi produkcji. Obecne zlecenie dotyczy przygotowania briefu i backlogu; nie wykonuj importu do Lineara ani publikacji w ramach przygotowywania dokumentacji. Podczas realizacji przyszły agent ma przejść wszystkie zadania, utrzymać działający build i ujawniać rzeczywiste blokady dostępu zamiast pozorować ukończenie. Konta wydawcy, dane prawne, zakupy usług i finalne ceny należą do właściciela produktu. Przygotowanie tych zależności jest częścią planu.

2. ZAKRES PRODUKTU

Obowiązkowo: onboarding, Sign in with Apple i email, profil preferencji, import pojedynczy i wielu zdjęć, kadrowanie i usuwanie tła, rozpoznawanie AI z korektą, szafa i jej wyszukiwanie, dostępność/pranie/archiwum, ręczne zestawy, 1–10 propozycji AI z zamianą elementu i feedbackiem, dziennik noszenia, CPW, kalendarz, statystyki, planer, pogoda, pakowanie na wyjazd, sprawdzenie dopasowania potencjalnego zakupu, powiadomienia opt-in, widget, eksport kolażu, subskrypcje, eksport danych i usunięcie konta. PL i EN, ceny szafy w PLN. Waluty sklepowe subskrypcji pochodzą ze StoreKit, niezależnie od PLN w szafie.

Poza tym wydaniem: Android, social feed i publiczne profile, marketplace, afiliacja, fotorealistyczna przymierzalnia na sylwetce, analiza ciała, automatyczne rozpoznawanie ubrania z kamery przez cały dzień, skanowanie paragonów i automatyczna konwersja walut. Są to granice produktu 1.0, nie pretekst do obniżenia jakości istniejących funkcji. Nie dodawaj ich bez zmiany specyfikacji.

Monetyzacja to założenie projektowe do zatwierdzenia: Free z ręczną szafą, historią i CPW; Plus z szerszym AI i dodatkowymi narzędziami. Miesięczny i roczny wariant jednej subskrypcji. Ceny, trial i limity ustala właściciel na podstawie kosztów. Nie obiecuj nielimitowanego AI. Po wygaśnięciu Plus dane pozostają dostępne do odczytu i eksportu, podstawowe funkcje ręczne nadal działają. Nie uzależniaj usunięcia konta od anulowania subskrypcji.

3. EKRANY I PRZEPŁYWY

Cztery zakładki: Dzisiaj, Szafa, Zestawy, Statystyki; planer/kalendarz w Dzisiaj i Zestawach, wyjazdy w Zestawach, ustawienia z profilu. Interfejs oparty na zdjęciach rzeczy i kolażach, neutralna paleta, duże akcje, natywne zachowanie iOS, dark mode, VoiceOver, Dynamic Type i Reduce Motion. Wszystkie przepływy mają empty, loading, error, offline i możliwość cofnięcia.

Onboarding wyjaśnia wartość, pozwala obejrzeć przykład, zbiera opcjonalne preferencje, prowadzi do dodania pierwszych rzeczy. Nie wymagaj płci, zdjęcia sylwetki ani numeru telefonu. Logowanie email i Apple musi obsłużyć powrót do aplikacji, private relay i wygasłe sesje. Proś o aparat, lokalizację i powiadomienia dopiero przy korzystaniu z danej funkcji.

Dodawanie: PhotosPicker lub aparat → kadr → segmentacja → analiza AI → edytowalny formularz → zapis. Wiele zdjęć to kolejka odrębnych draftów, nie próba wycięcia całej szafy z jednego zdjęcia. AI sugeruje kategorię, kolory, wzór, sezon i formalność; nie zgaduje ceny, daty i marki. Każdą sugestię można poprawić. Niepowodzenie AI lub segmentacji nie blokuje ręcznego zapisu. Duplikaty są jedynie ostrzeżeniem.

Szafa: siatka miniaturek, filtrowanie, wyszukiwanie, sortowanie, szczegóły, zdjęcie oryginalne i oczyszczone, cena, CPW i historia. Dostępność oddzielona od archiwizacji. Archiwizacja zachowuje historię. Trwałe usunięcie wymaga wyjaśnienia wpływu i usuwa zdjęcia oraz relacje; statystyki po nim mogą się zmienić.

Dzisiaj: aktualny plan, zapisane noszenie i propozycje. Kontekst AI: okazja, miasto/pogoda lub ręczna temperatura, preferencje, uwagi, liczba propozycji, przypięte ubranie. Karta pokazuje kolaż realnych rzeczy, krótkie uzasadnienie, zapis, zamianę elementu, feedback i „Noszę dzisiaj”. Zamiana może być ręczna lub AI, z zachowaniem reszty zestawu. Nie oznaczaj wygenerowania jako noszenia.

Zestawy: kolekcja, ulubione, kreator i planer przyszłych dni. Plany nie zwiększają CPW. Wyjazd: miejsce, daty i okazje → ograniczona lista rzeczy i plan zestawów → checklist pakowania. Zakup: zdjęcie rozważanej rzeczy jest tymczasowym kandydatem, nie elementem posiadanej szafy, dopóki użytkownik nie potwierdzi zakupu.

Statystyki: wartość znanych cen i liczba braków, rankingi CPW i noszeń, rzeczy nigdy nienoszone oraz nienoszone od 90 dni, z uwzględnieniem daty dodania. Filtr okresu dotyczy aktywności; CPW lifetime jest podpisane i nie miesza ceny lifetime z samymi noszeniami danego miesiąca. Brak danych jest jawny. Nie generuj bezpodstawnych twierdzeń o oszczędności lub ekologii.

Ustawienia: profil, język, miasto, zgody AI/analityka, przypomnienia, zakupy/restore, pomoc, polityki, eksport i usunięcie konta. Widget nie ujawnia niepotrzebnych danych; log out usuwa jego cache. Share sheet udostępnia wyłącznie świadomie wybrany kolaż.

4. NIEZMIENNE REGUŁY DOMENOWE

Jedno noszenie ubrania = jeden lokalny dzień kalendarzowy z co najmniej jednym zdarzeniem noszenia. Dwa zestawy tego samego dnia z tą samą rzeczą liczą ją raz. Cofnięcie jednego zdarzenia nie usuwa użycia pochodzącego z drugiego. Zapis, edycja i cofnięcie są atomowe i idempotentne, również po timeout i w synchronizacji offline. Daty przyszłe są planami, nigdy wear_events. Zmiana strefy nie przesuwa historycznego worn_on.

CPW = cena zakupu w groszach / liczba unikalnych dni noszenia. Bez float, zaokrąglenie dopiero przy prezentacji: 800 zł/100 dni = 8 zł; cena 0 = 0 zł przy co najmniej jednym dniu; cena nieznana = „Brak ceny”; brak dni = „Jeszcze nienoszone”. Nie sumuj CPW różnych rzeczy jako CPW całej szafy. Zmiana ceny przelicza wskaźnik, nie historię. Edycja zestawu nie zmienia listy rzeczy w poprzednim zdarzeniu.

Opcjonalne noszenia sprzed rozpoczęcia dziennika są osobną estymacją z datą graniczną. Pokaż oznaczenie estymacji i sumuj ją tylko z późniejszymi dniami; jawnie rozstrzygaj konflikty po zmianie granicy lub dodaniu starszej historii. Nie twórz fikcyjnych dat dla estymacji.

Kompletny zestaw: top+dół+buty albo sukienka/kombinezon+buty; warstwy opcjonalne zależnie od kontekstu. Niekompletna propozycja musi wskazać brak. Dostępność i własność są twardymi ograniczeniami, okazja/pogoda rankingiem stylistycznym. Przy niewystarczającej szafie zwróć mniej różnych zestawów zamiast wymyślać produkty.

5. ARCHITEKTURA I MODEL DANYCH

Natywny Swift/SwiftUI, async/await, lokalna baza i repozytoria. Nowe backendowe wdrożenie: zarządzany PostgreSQL, auth, private object storage i trwały worker. Konkretny dostawca wynika z ADR opartego na aktualnej dokumentacji i dostępie właściciela. Nie mnoż usług bez potrzeby; zachowaj istniejący poprawny stack repozytorium. Backend jest źródłem prawdy; mutacje offline zapisuj do outboxu z operation UUID. Rozwiązywanie konfliktów jest jawne: update z base_version, konflikt tej samej rzeczy wymaga rozstrzygnięcia, niezależne nowe wear_events można scalić. Tombstone wygrywa ze starą edycją. Zdjęcia offline są lokalnymi draftami do synchronizacji.

Podstawowe tabele z UUID, owner/user_id, czasami i wersją: profiles; garments; garment_images; outfits; outfit_items; wear_events; wear_event_items; preferences; outfit_feedback; ai_jobs; consent_events; planned_outfits; trips; trip_items; purchase_candidates; subscription_entitlements; subscription_events; usage_reservations; sync_operations; deletion_jobs; support_requests; operator_audit. Historia początkowa ubrania ma estimated_prior_wears i tracking_start_date. Opisz constraints i cykle życia w migracjach.

garments zawiera kategorię, podkategorię, kolory, wzór, sezony, formalność, cenę nullable w groszach, walutę PLN, markę i datę nullable, availability oraz archived_at. availability: available/laundry/unavailable. wear_events zawiera worn_on DATE, timezone, client_request_id oraz opcjonalne źródło zestawu. wear_event_items to własna historyczna lista ubrań. Nie licz użyć z bieżącej zawartości outfit_items. Unikalność (user_id,client_request_id) i constraints własności w relacjach są obowiązkowe. CPW i licznik wyliczaj z danych domenowych, nigdy z odpowiedzi AI.

API: CRUD/paginacja ubrań, zestawów, planów i podróży; upload/finalizacja; AI jobs i status; atomowe wear_events; statistics; synchronizacja zmian; eksport/usunięcie konta; weryfikacja zakupów i webhook Apple. Zdefiniuj OpenAPI lub równoważne schemy. Błędy mają code/message/request_id. Worker: lease, timeout, retry, deduplikacja, dead-letter, czyszczenie osieroconych obrazów. Dane i storage muszą być izolowane per właściciel, również przez tabele łączące.

6. AI I KOSZTY

AIProvider z oddzielną analizą obrazu i generowaniem stylizacji, wersjonowanymi promptami, JSON Schema i serwerową walidacją. Wybór realnego modelu po aktualnym sprawdzeniu dostępności, cen, retencji danych i wyników ewaluacji. Nie wpisuj sekretów do iOS. Używaj metadanych i wybranych miniaturek zamiast powtarzania całej szafy. Selekcja kandydatów zachowuje potrzebne kategorie i przypiętą rzecz nawet w szafie 1000 elementów.

Waliduj każde ID, własność, dostępność, kompletność, wykluczenia i duplikaty zestawów. Maksymalnie jedna naprawa niepoprawnego JSON. Tekst z obrazów i uwagi są niezaufanymi danymi. Ponownie waliduj szafę przy zapisie, bo mogła się zmienić. Kolaże są kompozycją prawdziwych zdjęć; nie zlecaj modelowi rysowania nowych ubrań.

Limity na użytkownika i globalny budżet, rezerwacje użycia, rozliczenie sukcesu i zwrot przy awarii, limity retry, timeout i kill switch. Zapisuj model, prompt_version, usage, koszt według wersjonowanego cennika i latencję bez surowych prywatnych danych w logach. Bez wsparcia idempotencji przez dostawcę nie gwarantuj braku podwójnego naliczenia po niejednoznacznym timeout; ogranicz ponowienia i monitoruj. Rezygnacja ze zgody AI uniemożliwia nowe wysyłki, w tym z zaległej kolejki.

Ewaluacja przed wydaniem: 100 oznaczonych przypadków. Twarde naruszenia własności/nieistniejących ID w prezentowanych wynikach = 0; testy automatyczne i walidator. Docelowo >=90% poprawnej kategorii na własnym zbiorze i >=80% zestawów uznanych za użyteczne przez oceniających według zapisanej rubryki. To proponowane bramki jakości do zmierzenia, nie obecne wyniki. Niska pewność klasyfikacji ma bezpieczny ręczny fallback.

7. PRYWATNOŚĆ I ZAKUPY

Zdjęcia prywatne, krótkotrwałe URL, brak EXIF/lokalizacji w uploadzie. Systemowy wybór zdjęć, dostęp do aparatu tylko na żądanie. Sesje w Keychain, brak sekretów administracyjnych w binary. Wylogowanie czyści cache poprzedniego konta i widget. Eksport i usunięcie obejmują zdjęcia, historię, plany i preferencje. Sprzątanie jest trwałym procesem odpornym na błędy; po restore ponownie zastosuj usunięcia.

Przed zewnętrznym AI pokaż konkretnego odbiorcę, jakie dane otrzyma i w jakim celu, i uzyskaj zgodę. Wersja zgody i wybór użytkownika są zapisane. Nie sprzedawaj zdjęć i nie włączaj treningu na danych użytkownika. Polityka ma odpowiadać rzeczywistym umowom i retencji wybranych usług, nie obietnicom bez pokrycia. Lokalizacja jest opcjonalna i tylko podczas użycia; ręczne miasto jest alternatywą. Bez reklam i śledzenia między aplikacjami w wydaniu 1.0.

StoreKit po stronie iOS oraz weryfikowane serwerowo uprawnienia i powiadomienia Apple. Obsłuż restore, pending, refund/revoke, wygaśnięcie, grace period i billing retry. Kwoty ze StoreKit, bez hardcode. Wyraźnie opisz odnawianie i warunki trial, jeśli go skonfigurowano. Usunięcie konta nie jest anulowaniem subskrypcji Apple; pokaż informację i zarządzanie zakupami bez blokowania samego usunięcia.

8. JAKOŚĆ, OPERACJE I WYDANIE

Oddzielone dev/staging/prod, CI na macOS, testy jednostkowe domeny, integracyjne izolacji danych i transakcji, E2E najważniejszych ścieżek i testy StoreKit/sandbox. Testuj na fizycznym iPhonie, nie tylko symulatorze: HEIC/aparat, deep links Apple/email, widget, powiadomienia, zakupy, duży tekst, VoiceOver, offline i dwa urządzenia. Brak macOS lub uprawnień to jawna blokada, nie zaliczony build.

Proponowane mierzalne cele wydania: brak otwartych blockerów/krytycznych usterek i luk wysokiego ryzyka; warm launch p95 <=2 s na uzgodnionym urządzeniu; zwykłe API p95 <=800 ms bez upload i AI; AI p95 <=30 s; >=99,5% sesji bez crashy w becie z podaniem rozmiaru próby. Przetestuj 1000 rzeczy i 5 lat historii. Czasy to cele do walidacji na zapisanym profilu urządzenia i sieci, a nie gwarancja dla każdej sytuacji.

Monitoring błędów i symbolikacja, alarmy kosztów, metryki kolejek, synchronizacji i zakupów. Minimalny panel operacyjny z rolami, MFA i audit log, bez domyślnego przeglądania zdjęć. Runbook awarii AI, błędów płatności, eksportu/usunięć, rotacji sekretów, backup/restore i hotfix. Proponowane RPO 24 h i RTO 8 h potwierdź ćwiczeniem. Wskaż osoby odpowiedzialne za support i alarmy.

Publikacja: Apple Developer i App Store Connect, bundle ID, podpisywanie i aktualny wymagany SDK; rzeczywiste dane wydawcy, umowy/podatki jeśli potrzebne; produkty IAP; polityka i support URL; PL/EN metadata, screenshots z prawdziwego buildu i finalna ikona; privacy labels, manifests/required-reason APIs, age rating i export compliance zgodne z realną implementacją. Zweryfikuj aktualne wymagania ponownie przy wysyłce. Zapewnij działającą ścieżkę review i notatki o AI/zakupach. TestFlight minimum 7 dni z co najmniej 10 zaproszonymi testerami oraz faktycznym raportem aktywności. Napraw feedback, wyślij release candidate, obsłuż review, opublikuj, sprawdź wersję pobraną ze sklepu i monitoruj przez 72 h. Akceptacji Apple nie można zagwarantować.

Definition of Done: wszystkie funkcje zakresu działają z produkcyjnymi usługami, wymagane testy i bramki mają dowody, właściciel może utrzymać produkt, build jest zaakceptowany i faktycznie dostępny w App Store. Release-ready oraz Published to odrębne statusy.

9. BACKLOG I PRZENIESIENIE DO LINEARA

Dołączony JSON jest kanonicznym backlogiem dla agenta: 10 epików, 70 zadań, stabilne external_id, zależności, kryteria odbioru, priorytet i milestone. Nie jest obietnicą zgodności z natywnym importerem Lineara. Agent mapuje go do aktualnego API/integracji i wybranego workspace/team. Brak estymat jest celowy: uzupełnij po inspekcji repo i dostępu do usług, nie zgaduj czasu.

Mapowanie: jeden projekt produktu, jeden milestone App Store 1.0, epiki jako nadrzędne issues, zadania jako sub-issues; stable external_id zachowaj w opisie lub uzgodnionym polu. Tytuł issue: [Txxx] tytuł. Opis zawiera zakres, AC i identyfikator. depends_on mapuj jako blocked by dopiero po utworzeniu wszystkich issues. Priority 1=High, 2=Normal; nie wymuszaj nieistniejących statusów/etykiet. Twórz w dwóch przebiegach: najpierw issues i mapa ID, następnie relacje. Wznawianie nie może dublować zadań. Nie dodawaj fikcyjnych assignee, sprintów i terminów. Zadania zewnętrzne pozostają otwarte do rzeczywistego wykonania przez właściciela/uprawnionego agenta.

Etapy to porządek implementacji, nie ograniczenie zakresu: fundamenty → konto/szafa/synchronizacja → AI i CPW → planer/narzędzia → zakupy → jakość → beta → App Review → publikacja i utrzymanie. Zależności w JSON precyzują kolejność; sprawdź je po każdej zmianie zakresu.

10. ŹRÓDŁA WYMAGAŃ WYDAWNICZYCH

Apple App Review Guidelines, zwłaszcza 2.1, 3.1, 4.8, 5.1.1 i 5.1.2:
https://developer.apple.com/app-store/review/guidelines/
Usuwanie konta i subskrypcje przy usunięciu:
https://developer.apple.com/support/offering-account-deletion-in-your-app/
Źródła sprawdzone 1 listopada 2026. Reguły wydawnicze aktualizują się; ponowna kontrola przed submission jest zadaniem T064.

11. LISTA ZADAŃ

E01 — Produkt i projekt UX

T001 Zatwierdź specyfikację produktu 1.0
Priorytet: Normal | Zależności: brak
Zakres i odbiór: Spisz kompletną macierz funkcji Free/Plus, kraj startowy Polska, języki PL/EN, walutę PLN oraz decyzje właściciela. Nie wpisuj fikcyjnych cen ani danych prawnych. Lista decyzji ma właściciela i blokowane zadania.

T002 Zaprojektuj wszystkie przepływy i stany
Priorytet: Normal | Zależności: T001
Zakres i odbiór: Dostarcz projekt ekranów dla onboardingu, szafy, AI, historii, planera, statystyk, płatności i ustawień. Każdy przepływ ma loading, empty, error, offline oraz ścieżkę powrotu.

T003 Zbuduj system wizualny i lokalizację
Priorytet: Normal | Zależności: T002
Zakres i odbiór: Zdefiniuj kolory, typografię, komponenty, dark mode i PL/EN w String Catalog. Długie teksty i Dynamic Type nie zasłaniają akcji.

T004 Przetestuj prototyp z użytkownikami
Priorytet: Normal | Zależności: T002
Zakres i odbiór: Przeprowadź co najmniej 5 sesji z dostępnymi testerami; sprawdź dodanie ubrania, wybór zestawu i zapis noszenia. Udokumentuj obserwacje i popraw blokujące problemy; bez testerów pozostaw zadanie otwarte.

E02 — Platforma i infrastruktura

T005 Utwórz projekt iOS i architekturę
Priorytet: Normal | Zależności: T003
Zakres i odbiór: SwiftUI, async/await, moduły funkcjonalne, repozytoria i DI. Czysty checkout buduje się na udokumentowanym stabilnym Xcode; mock nie jest domyślnym backendem release.

T006 Przygotuj środowiska i CI
Priorytet: Normal | Zależności: T005
Zakres i odbiór: Oddziel dev/staging/prod, konfigurację i podpisywanie. CI na macOS uruchamia build i testy; skan sekretów przechodzi; release nie łączy się ze stagingiem.

T007 Wybierz i skonfiguruj backend
Priorytet: Normal | Zależności: T001
Zakres i odbiór: Zapisz ADR z aktualną dokumentacją, regionem, kosztami i trwałością zadań. PostgreSQL, auth, private storage i worker działają na staging; konta i płatne zasoby wymagają realnych uprawnień właściciela.

T008 Zaimplementuj schemat i migracje
Priorytet: High | Zależności: T007
Zakres i odbiór: Utwórz tabele opisane w briefie, indeksy, relacje własności, constraints i polityki dostępu. Migracja na pustej bazie i aktualizacja poprzedniej wersji przechodzą testy.

T009 Zbuduj kontrakty API i klienta
Priorytet: Normal | Zależności: T005, T008
Zakres i odbiór: Wersjonowane DTO i schemy, paginacja, walidacja, błędy z request_id i idempotencja mutacji. Powtórzenie zapisu po timeout nie dubluje danych.

T010 Zaimplementuj trwałe zadania
Priorytet: Normal | Zależności: T009
Zakres i odbiór: Worker ma lease, timeout, ograniczone retry, deduplikację i dead-letter. Restart nie gubi analizy ani nie nalicza podwójnie limitu; status można odczytać po ponownym otwarciu aplikacji.

T011 Zbuduj prywatny pipeline obrazów
Priorytet: Normal | Zależności: T008, T010
Zakres i odbiór: Podpisane uploady, walidacja dekodowania i limitów, miniatury, usunięcie EXIF, sprzątanie osieroconych plików. Nieautoryzowany użytkownik nie odczytuje obiektu ani podpisanego URL po wygaśnięciu.

T012 Zaimplementuj synchronizację offline
Priorytet: High | Zależności: T009
Zakres i odbiór: Lokalna baza, outbox z UUID, wersjonowanie rekordów, tombstones, retry i konflikt. Dodanie/edycja ubrania oraz noszenie działają offline, synchronizują się bez duplikatów; usunięcie konta wygrywa z zaległymi zapisami.

E03 — Konto i prywatność

T013 Dodaj Sign in with Apple i email
Priorytet: Normal | Zależności: T009
Zakres i odbiór: Obie metody działają na urządzeniu, również Apple private relay, ponowne logowanie i wygasła sesja. Łączenie tożsamości wymaga potwierdzenia i nie scala kont po samym adresie email.

T014 Zbuduj onboarding i profil
Priorytet: Normal | Zależności: T013, T003
Zakres i odbiór: Użytkownik wybiera opcjonalne style, kolory i preferencje; może pominąć onboarding. Nie wymagaj płci, rozmiaru ani zdjęcia sylwetki. Pokazuj wartość przed paywallem.

T015 Zaimplementuj zgody i ustawienia prywatności
Priorytet: Normal | Zależności: T014
Zakres i odbiór: Przed zewnętrznym AI pokaż odbiorcę, dane i cel; zapisz wersję zgody. Odmowa i cofnięcie blokują nowe wysyłki AI oraz anulują niewysłane zadania; ręczna szafa działa dalej.

T016 Dodaj eksport danych
Priorytet: Normal | Zależności: T011, T013
Zakres i odbiór: Użytkownik zamawia prywatny eksport JSON oraz zdjęć; archiwum ma krótki okres dostępności. Eksport obejmuje historię, plan i ceny, nie obejmuje cudzych danych i sekretów.

T017 Zaimplementuj usunięcie konta
Priorytet: High | Zależności: T013, T015
Zakres i odbiór: Usunięcie dostępne w aplikacji, reautoryzacja, cofnięcie tokenów Apple, unieważnienie sesji i trwałe sprzątanie danych/zdjęć. Ponowienie jest bezpieczne; retencja backupów odpowiada polityce.

T018 Przygotuj polityki i kanał wsparcia
Priorytet: Normal | Zależności: T001, T015, T017
Zakres i odbiór: Opublikuj Privacy Policy, warunki, support i opis podwykonawców zgodne z rzeczywistymi przepływami. Właściciel uzupełnia administratora i dane kontaktowe; brak placeholderów w release.

E04 — Cyfrowa szafa

T019 Dodaj aparat i import wielu zdjęć
Priorytet: Normal | Zależności: T005, T011
Zakres i odbiór: Obsłuż JPEG/HEIC, orientację, anulowanie, odmowę aparatu, limit 10 MB i kompresję do 1600 px. Import wielu zdjęć ma osobny status każdej rzeczy i nie gubi częściowych sukcesów.

T020 Dodaj kadrowanie i usuwanie tła
Priorytet: Normal | Zależności: T019
Zakres i odbiór: Edytowalny kadr, podgląd przed/po, zachowanie oryginału i fallback przy błędzie segmentacji. Użytkownik może zaakceptować zdjęcie bez usuniętego tła.

T021 Zaimplementuj formularz ubrania
Priorytet: Normal | Zależności: T008, T019
Zakres i odbiór: Nazwa, kategoria, paleta kolorów, wzór, sezony, formalność, marka, cena i data zakupu. Cena w groszach, brak ceny różny od zera, walidacja i ręczna korekta AI.

T022 Zbuduj szafę i szczegóły
Priorytet: Normal | Zależności: T021, T012
Zakres i odbiór: Siatka miniaturek, wyszukiwanie, filtry, sortowanie, szczegóły i historia. Przy 1000 rzeczach paginacja nie pobiera wszystkich oryginałów; stany offline są czytelne.

T023 Dodaj dostępność i archiwizację
Priorytet: Normal | Zależności: T022
Zakres i odbiór: Dostępne, pranie, niedostępne oraz archiwalne. Zmiana synchronizuje się między urządzeniami, wyklucza z AI i zachowuje historię oraz CPW.

T024 Zaimplementuj trwałe usunięcie ubrania
Priorytet: Normal | Zależności: T023, T017
Zakres i odbiór: Zwykłą akcją jest archiwizacja; trwałe usunięcie wyjaśnia wpływ na historię, usuwa zdjęcia i relacje, przelicza agregaty. Kolejka offline nie odtwarza usuniętej rzeczy.

T025 Dodaj wykrywanie potencjalnych duplikatów
Priorytet: Normal | Zależności: T020, T022
Zakres i odbiór: Hash/perceptual similarity proponuje sprawdzenie podobnej rzeczy, bez automatycznego scalania. Użytkownik może zachować dwa identyczne egzemplarze.

T026 Zbuduj ręczny kreator zestawów
Priorytet: Normal | Zależności: T022
Zakres i odbiór: Wybór ubrań, kolaż, zapis, nazwa, edycja i ulubione. Zestaw nie zmienia wcześniejszych zapisów noszenia; archiwalny element ma widoczne ostrzeżenie.

E05 — Stylista AI

T027 Zbuduj adapter dostawcy AI
Priorytet: Normal | Zależności: T010, T015
Zakres i odbiór: Konfiguracja modelu na serwerze, analiza obrazu i rekomendacje jako oddzielne operacje. Sekrety nie trafiają do binary, są timeouty, pomiar użycia i deterministyczne mocki testowe.

T028 Zaimplementuj rozpoznawanie ubrań
Priorytet: Normal | Zależności: T027, T021
Zakres i odbiór: Schema metadanych, walidacja enumów, pewność i multiple_items. Nie zgaduj ceny, daty ani marki. Niska pewność wymaga korekty; wynik pozostaje draftem do zatwierdzenia.

T029 Zbuduj selekcję kandydatów
Priorytet: Normal | Zależności: T023, T027
Zakres i odbiór: Filtrowanie własności i dostępności, reprezentacja kategorii, preferencje, okazja oraz przypięte ubranie. Test szafy 1000 rzeczy nie wysyła wszystkich obrazów do modelu.

T030 Zaimplementuj generowanie zestawów
Priorytet: Normal | Zależności: T029
Zakres i odbiór: Zwracaj 1–10 propozycji, domyślnie 3, tylko z istniejących ID. JSON, kontrola kompletności, deduplikacja i maksymalnie jedna próba naprawy; mniejsza liczba propozycji ma wyjaśnienie.

T031 Zbuduj ekran propozycji i zamianę elementu
Priorytet: Normal | Zależności: T030, T026
Zakres i odbiór: Kolaże realnych zdjęć, powód dopasowania, zapis, noszenie i zamiana jednej rzeczy z zachowaniem pozostałych. Ręczna zamiana dostępna przy awarii AI.

T032 Dodaj preferencje i feedback
Priorytet: Normal | Zależności: T031, T014
Zakres i odbiór: Lubię/nie lubię z opcjonalnym powodem, wykluczenia oraz reset personalizacji. Rekomendacje respektują twarde wykluczenia; feedback nie zmienia historii noszenia.

T033 Zbuduj zestaw ewaluacyjny AI
Priorytet: Normal | Zależności: T028, T030
Zakres i odbiór: Co najmniej 100 przypadków prawidłowo oznaczonych i legalnych zdjęć/kontekstów, w tym mała szafa, brak butów, zima, konflikty preferencji i wstrzyknięte instrukcje. Raport porównuje wersje promptów bez wycieku danych.

T034 Dodaj limity kosztów i ochronę AI
Priorytet: Normal | Zależności: T027, T033
Zakres i odbiór: Per-user quota, globalny budżet, rezerwacja/rozliczenie, ograniczone retry i kill switch. Failed job zwalnia rezerwację; dostawca bez idempotencji nie ma deklaracji exactly-once przy utracie odpowiedzi.

E06 — Historia i analityka szafy

T035 Zaimplementuj zapis i edycję noszenia
Priorytet: High | Zależności: T026, T012
Zakres i odbiór: Oddzielne wear_events i lista rzeczy, lokalna data oraz strefa. Idempotencja i atomowość, przyszłe daty odrzucone; dwa zestawy jednego dnia nie podwajają licznika wspólnej rzeczy.

T036 Zbuduj silnik CPW
Priorytet: High | Zależności: T035
Zakres i odbiór: Cena w groszach / unikalne dni noszenia, zaokrąglenie przy wyświetleniu. Testy 0, null, brak dni, cofnięcie, współdzielone rzeczy i edycja ceny. LLM nie liczy statystyk.

T037 Dodaj historię początkową ubrania
Priorytet: Normal | Zależności: T036
Zakres i odbiór: Opcjonalna estymacja noszeń sprzed rozpoczęcia dziennika i data graniczna. CPW estymowane oznaczone, dni dziennika po granicy nie dublują bazowych noszeń; zmiana granicy wymaga jawnego rozstrzygnięcia nakładania.

T038 Zbuduj kalendarz historii
Priorytet: Normal | Zależności: T035
Zakres i odbiór: Przegląd dat, dodanie, edycja i cofnięcie wpisu z undo. Zmiana strefy nie przesuwa istniejących dni; aktualizacja zestawu nie zmienia historycznej listy rzeczy.

T039 Zbuduj statystyki szafy
Priorytet: Normal | Zależności: T036, T037
Zakres i odbiór: Wartość znanych cen z liczbą brakujących, rankingi CPW, najczęściej noszone, nigdy nienoszone i nieużywane 90 dni. Filtrowanie dat dotyczy aktywności; lifetime CPW jest podpisane i nie zmienia mianownika na okresowy.

T040 Dodaj listę rzeczy do przeglądu
Priorytet: Normal | Zależności: T039
Zakres i odbiór: Użytkownik widzi rzadko noszone rzeczy z opcją przypomnij zestaw, zachowaj lub archiwizuj. Nie deklaruj oszczędności ani wpływu środowiskowego bez danych.

E07 — Planowanie i funkcje iOS

T041 Zbuduj planer stylizacji
Priorytet: Normal | Zależności: T026, T038
Zakres i odbiór: Plan na przyszły dzień jest oddzielny od noszenia. Przenoszenie i usuwanie planu nie zmienia CPW; dopiero jawne potwierdzenie tworzy wear_event.

T042 Dodaj pogodę i miasto
Priorytet: Normal | Zależności: T015, T030
Zakres i odbiór: Ręczny wybór miasta lub opcjonalna lokalizacja tylko podczas użycia. Prognoza ma czas aktualizacji, strefę miasta i fallback ręczny; brak zgody nie blokuje propozycji.

T043 Zbuduj pakowanie na wyjazd
Priorytet: Normal | Zależności: T041, T042
Zakres i odbiór: Daty, miejsce, okazje i ograniczenie liczby rzeczy; lista pakowania i zestawy na dni. Każda rzecz jest z własnej szafy, powtórki są celowe, brakujące kategorie jawne; odhaczenie pakowania nie liczy noszenia.

T044 Dodaj sprawdzenie rzeczy przed zakupem
Priorytet: Normal | Zależności: T028, T030
Zakres i odbiór: Zdjęcie potencjalnego zakupu tworzy odrębny tymczasowy obiekt; AI pokazuje dopasowania do własnej szafy. Dopiero potwierdzenie zakupu dodaje ubranie; bez prognozowania przyszłego CPW jako faktu.

T045 Dodaj przypomnienia
Priorytet: Normal | Zależności: T041, T015
Zakres i odbiór: Opt-in lokalne powiadomienia o planie i zapisie noszenia; quiet hours, strefy, anulowanie i deep link. Odmowa powiadomień nie ogranicza aplikacji.

T046 Zbuduj widget i skrót noszenia
Priorytet: Normal | Zależności: T035, T041
Zakres i odbiór: WidgetKit pokazuje plan/dzisiaj z ochroną prywatności; App Intent otwiera potwierdzenie noszenia. Brak tokenów w współdzielonym magazynie; wylogowanie czyści widget.

T047 Dodaj eksport kolażu zestawu
Priorytet: Normal | Zależności: T026
Zakres i odbiór: Systemowy share sheet eksportuje wyłącznie wybrany kolaż i tekst bez prywatnych cen/identyfikatorów. Brak automatycznej publikacji i publicznego profilu.

E08 — Subskrypcje

T048 Zdefiniuj ofertę Free i Plus
Priorytet: Normal | Zależności: T001, T034
Zakres i odbiór: Propozycja: Free ręczna szafa/historia/CPW, Plus rozszerzone AI, planer wyjazdu i zakupy. Ceny, trial i limity wymagają decyzji właściciela po pomiarze kosztów; macierz i fallback zapisane przed konfiguracją produktów.

T049 Zaimplementuj zakupy StoreKit
Priorytet: Normal | Zależności: T048, T013
Zakres i odbiór: Produkty miesięczny/roczny z jednej grupy, lokalizowane ceny ze sklepu, pending/cancel/success i brak internetu. Transakcje weryfikowane; żadnych cen wpisanych na sztywno.

T050 Zbuduj serwer uprawnień
Priorytet: High | Zależności: T049, T009
Zakres i odbiór: Weryfikacja Apple i powiadomienia serwerowe, deduplikacja, sandbox/prod, odnowienie, wygaśnięcie, grace period, refund i revoke. Zmiana zegara/patch klienta nie odblokowuje AI.

T051 Dodaj paywall i zarządzanie zakupami
Priorytet: Normal | Zależności: T049, T050
Zakres i odbiór: Jasne okresy, cena, trial jeśli skonfigurowany, linki polityk, restore i manage subscriptions. Można zamknąć paywall, utrata Plus nie usuwa danych ani nie blokuje eksportu.

T052 Przetestuj cały cykl subskrypcji
Priorytet: Normal | Zależności: T051, T017
Zakres i odbiór: StoreKit tests i sandbox na urządzeniu: kupno, restore, drugie urządzenie, refund, revoke, billing retry, reinstall oraz konto usuwane z aktywną subskrypcją. Ostrzeżenie: usunięcie konta samo nie anuluje płatności Apple.

E09 — Jakość i operacje

T053 Dodaj monitoring i metryki produktu
Priorytet: Normal | Zależności: T009, T034
Zakres i odbiór: Crash reporting z symbolami, latencje, błędy synchronizacji, skuteczność zadań i koszt AI. Zdarzenia aktywacji bez zdjęć i treści szafy; respektuj wybory analityki.

T054 Zbuduj minimalny panel operacyjny
Priorytet: Normal | Zależności: T053
Zakres i odbiór: Role, MFA i audit log; status usług, kolejki, koszty, feature flags i obsługa zgłoszeń. Domyślnie bez dostępu do prywatnych zdjęć i impersonacji; każda zmiana konfiguracji audytowana.

T055 Zaimplementuj backup i odtwarzanie
Priorytet: Normal | Zależności: T008, T011
Zakres i odbiór: Backup bazy oraz strategia zdjęć, ćwiczenie restore na odizolowanym środowisku. Proponowane cele RPO 24 h i RTO 8 h zweryfikowane pomiarem; ponownie zastosuj usunięcia po restore.

T056 Przeprowadź test bezpieczeństwa
Priorytet: High | Zależności: T017, T024, T050, T054
Zakres i odbiór: Test IDOR, storage, relacji cross-tenant, uploadów, limitów, tokenów i prompt injection; skan zależności. Krytyczne/wysokie problemy rozwiązane lub release pozostaje zablokowany.

T057 Przeprowadź testy dostępności i języków
Priorytet: Normal | Zależności: T003, T031, T039, T051
Zakres i odbiór: VoiceOver pełnych przepływów, największy wspierany tekst, kontrast, Reduce Motion, PL/EN i dark mode na urządzeniu. Brak zasłoniętych krytycznych akcji.

T058 Przeprowadź testy offline i konfliktów
Priorytet: Normal | Zależności: T012, T035, T041
Zakres i odbiór: Dwa urządzenia, równoczesna edycja, tombstone kontra stary outbox, utrata sieci w uploadzie i wylogowanie. Brak utraty noszeń, wskrzeszania danych i cudzych cache.

T059 Zmierz wydajność i niezawodność
Priorytet: Normal | Zależności: T022, T030, T053
Zakres i odbiór: Test 1000 rzeczy i 5 lat historii. Proponowane bramki: warm launch p95 <=2 s na wskazanym urządzeniu, tekstowe API p95 <=800 ms bez AI/upload, AI p95 <=30 s; opisz warunki i popraw przekroczenia.

T060 Przeprowadź pełne testy regresji
Priorytet: High | Zależności: T043, T044, T046, T047, T052, T056, T057, T058, T059
Zakres i odbiór: Prawdziwy backend i AI na staging, kluczowe scenariusze E2E, build release bez debug funkcji. Wszystkie P0/P1 zamknięte, raport wskazuje testy faktycznie wykonane.

E10 — Publikacja i utrzymanie

T061 Przygotuj konto wydawcy i podpisywanie
Priorytet: Normal | Zależności: T001
Zakres i odbiór: Właściciel zapewnia Apple Developer/App Store Connect, bundle ID, role, umowy i dane podatkowe gdy potrzebne. Certyfikaty i profile działają w CI, brak ujawnionych kluczy.

T062 Przeprowadź betę TestFlight
Priorytet: Normal | Zależności: T060, T061, T004
Zakres i odbiór: Zbierz realny feedback przez minimum 7 dni od co najmniej 10 zaproszonych testerów; raportuj faktyczną aktywność. Cel >=99,5% sesji bez crashy przy podanej próbie; mała próba wymaga jawnej oceny, nie fikcyjnego wyniku.

T063 Przygotuj stronę sklepu i materiały
Priorytet: Normal | Zależności: T003, T018, T061
Zakres i odbiór: Finalna nazwa po weryfikacji dostępności, ikona, PL/EN, screenshots z rzeczywistego buildu, opis, słowa kluczowe, support/privacy URL. Materiały nie obiecują funkcji spoza wydania.

T064 Wypełnij zgodność App Store
Priorytet: Normal | Zależności: T015, T018, T052, T056, T063
Zakres i odbiór: Sprawdź aktualne reguły Apple, privacy labels, SDK manifests/required-reason APIs, age rating, export compliance i dane wydawcy. Formularze odpowiadają realnemu buildowi i wymagają prawdziwych danych właściciela.

T065 Przygotuj release candidate i instrukcję review
Priorytet: High | Zależności: T062, T064
Zakres i odbiór: Archive waliduje się, produkcyjny backend działa, konto review/ścieżka dostępu działa bez prywatnych OTP właściciela. Opisz AI, zgody i zakupy; żadnych placeholderów ani niedostępnych funkcji.

T066 Wyślij aplikację do App Review
Priorytet: Normal | Zależności: T065
Zakres i odbiór: Uprawniony wydawca wysyła dokładnie zweryfikowany build i produkty IAP. Zapisz numer buildu oraz faktyczny status review; nie oznaczaj jako opublikowane po samym uploadzie.

T067 Obsłuż uwagi App Review
Priorytet: Normal | Zależności: T066
Zakres i odbiór: Udziel zgodnych z prawdą wyjaśnień, popraw zgłoszone problemy, wykonaj regresję i ponownie wyślij w razie potrzeby. Zamknij po akceptacji lub potwierdzeniu braku uwag.

T068 Opublikuj i zweryfikuj produkcję
Priorytet: High | Zależności: T067, T055
Zakres i odbiór: Wydawca wykonuje release, sprawdza publiczny listing i wersję z App Store, logowanie, AI, noszenie, CPW i zakup. Zachowaj procedurę zatrzymania rollout i wyłączenia wadliwej funkcji.

T069 Monitoruj wydanie i przygotuj poprawki
Priorytet: Normal | Zależności: T068, T053
Zakres i odbiór: Przez pierwsze 72 h monitoruj awarie, koszty, zakupy i support; przypisz dyżur. Krytyczne błędy mają hotfix i plan komunikacji; nie zakładaj możliwości natychmiastowego rollback binarnego.

T070 Przekaż dokumentację utrzymania
Priorytet: Normal | Zależności: T069
Zakres i odbiór: Repo, runbook, migracje, backup, alarmy, wydania, rotacja sekretów i obsługa prywatności mają właściciela. Lista otwartych drobnych problemów oraz terminy aktualizacji są jawne.
