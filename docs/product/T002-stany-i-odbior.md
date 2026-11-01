# T002 — Macierz stanów i odbiór projektu

Integralna część [projektu ekranów](T002-projekt-przeplywow.md), wersja 1.0.
Identyfikatory F01–F20 wskazują przepływy, a identyfikatory ekranów prowadzą do
ich układów w projekcie. Każdy wiersz ma pięć wymaganych stanów; zachowanie
normalne i zakończenie opisano przy ekranach. To specyfikacja zachowania do
implementacji, nie raport z wykonanych testów aplikacji.

## Reguły wspólne

- Loading: widoczny opis czynności, bez fikcyjnego procentu. Dane już dostępne
  zostają na ekranie podczas odświeżania. Blokowana jest tylko akcja, której
  powtórzenie koliduje z trwającą operacją; powrót pozostaje dostępny.
- Empty rozróżnia pierwszy start, brak wyników filtra i rzeczywisty brak danych.
  Nie zastępuje błędu sieci. Każdy stan podaje następny możliwy krok.
- Error: zrozumiały komunikat, zachowany formularz i akcja naprawcza. Szczegóły
  wsparcia mogą zawierać request_id, nigdy sekret lub surowe prywatne dane.
- Offline: widoczny czas ostatniej synchronizacji i status lokalnych zmian.
  Nie nazywamy cache aktualnym wynikiem serwera. Niewysłane operacje konta
  pozostają oddzielone od danych innych kont. Przeciągnięcie do odświeżenia
  przy braku sieci nie usuwa treści.
- Powrót: zachowuje stan rodzica i draft zgodnie z projektem. Dla długiego
  zadania opuszczenie ekranu nie oznacza jego anulowania. Trwałe usuwanie
  wymaga potwierdzenia, bez fałszywego przycisku cofania po wykonaniu.
- Kombinacje: lokalny błąd pola zostaje przy polu również offline; wygasła
  sesja blokuje dostęp do serwera, ale nie kasuje draftu tego konta. Brak zgody
  AI blokuje wysyłkę nawet po odzyskaniu sieci i Plus. Tombstone/usunięcie
  konta ma pierwszeństwo przed zaległą edycją. Status zakupu nie znika pod
  ogólnym komunikatem offline.

## Pełna macierz stanów

| Przepływ i ekrany | Loading | Empty | Error i odzyskanie | Offline | Powrót / anulowanie |
| --- | --- | --- | --- | --- | --- |
| F01 Onboarding, O01–O03 | Lokalny przykład bez wymogu sieci; przy zapisie preferencji „Zapisuję” | Brak preferencji jest poprawny; „Pomiń”; brak ubrań → „Dodaj pierwszą rzecz” | Błąd zapisu zachowuje wybór; „Ponów” lub „Później” | Przykład, preferencje lokalne i draft dostępne; konto/sync później | Wstecz między krokami; Pomiń/Później → D01; bez samoczynnego powtarzania ukończonych kroków |
| F02 Konto i sesja, A01–A03 | „Loguję” / „Wysyłam link”; ponowna wysyłka wstrzymana na czas odpowiedzi | Pusty email → wskazówka i walidacja po próbie; brak konta → opcja rozpoczęcia rejestracji | Wygasły link → nowy; anulowanie Apple → A01; private relay akceptowany; konflikt tożsamości → weryfikacja, bez scalenia | „Połącz się, aby się zalogować”; lokalny przykład/draft pozostają; retry po powrocie sieci | Zamknij → ekran źródłowy; popraw email bez utraty celu; po sukcesie wróć do celu deep linku |
| F03 Import i rozpoznanie, I01–I04, U03 | Osobny postęp draftu: obróbka/analiza/zapis; formularz ręczny dostępny | Pusta kolejka → PhotosPicker/aparat; brak sugestii → formularz ręczny | Odmowa aparatu → picker; zły plik → wybierz ponownie; segmentacja → oryginał; AI → popraw ręcznie; błąd pojedynczego draftu nie blokuje innych | Lokalne zdjęcie/kadr/formularz i zapis z etykietą oczekiwania; zdalna analiza/upload wymagają sieci i zgody, bez obietnicy automatycznej analizy | Anulowanie pickera → źródło; z formularza zachowaj draft/odrzuć/kontynuuj; zapis → następny draft albo W02 |
| F04 Szafa i szczegóły, W01–W03 | Szkielet przy pierwszym pobraniu; kolejne strony z wskaźnikiem u dołu; zapis/archiwizacja przy akcji | Pusta szafa → Dodaj; brak wyników → Wyczyść filtry; puste archiwum → wróć do aktywnych | Retry pobrania strony bez utraty siatki; błąd walidacji → pole; rekord usunięty → komunikat i W01 | Cache i lokalne mutacje z outboxem; brak pobranego zdjęcia → placeholder, nie fałszywe zdjęcie; usunięcie oznaczone jako oczekujące | W02 → źródło z filtrami/pozycją; W03 Anuluj → W02; usunięcie → lista; archiwizacja ma Przywróć |
| F05 Sync i konflikty, Y01 | „Synchronizuję N zmian”; dla niepewnego zapisu sprawdzanie statusu istniejącej operacji | Brak zaległości → „Wszystko zsynchronizowane” tylko po potwierdzeniu; bez potwierdzenia „Brak lokalnych zmian” | Porównanie wersji → świadomy wybór; błąd retry zachowuje outbox; tombstone → informacja bez nadpisania | Liczba oczekujących i ostatnia synchronizacja; szczegóły konfliktu tylko jeśli dostępne lokalnie; rozstrzygnięcie wymaga aktualnej wersji serwera | Zamknij → źródło, kolejka trwa; konflikt można odłożyć, nigdy automatycznie uznać za rozwiązany |
| F06 Dzisiaj i pogoda, D01, G01 | Osobno plan i pogoda; opóźnienie pogody nie blokuje ręcznego kontekstu | Brak planu → Zaplanuj/Utwórz zestaw; brak miasta → wpisz miasto; brak noszeń → Dodaj noszenie | Pogoda niedostępna → temperatura ręczna; odmowa lokalizacji → miasto; błąd planu → retry | Plan z cache z datą; pogoda z czasem lub „Brak aktualnej pogody”; ręczna temperatura; noszenie zapisuje się lokalnie | Anuluj miasto/kontekst → D01; przełączenie zakładki zachowuje kontekst; H03 ma Anuluj |
| F07 AI, wyniki i zamiana, G01–G03 | Kolejka/analiza; stan istniejącego zadania po wznowieniu; zamiana blokuje tylko zmieniany slot | Za mało rzeczy → konkretne braki, mniej wyników lub ręczny kreator; zero wyników nie udaje sukcesu | Niepoprawny wynik/awaria/kill switch → ręcznie; limit → stan limitu i oferta tylko gdy zasadna; timeout → sprawdź status; niedostępna rzecz → wybierz zamiennik | Wcześniej zapisane wyniki z cache; bez nowej generacji; ręczny kreator/zamiana dostępne; ponowna walidacja przy synchronizacji | Zamknij postęp → D01/Z01, zadanie trwa; Anuluj zamianę → oryginalna karta; zamknięcie oferty wraca do kontekstu |
| F08 Ręczne zestawy i feedback, Z01–Z03, G03 | Ładowanie kolekcji; stan zapisu zestawu/feedbacku przy akcji | Brak zestawów → Utwórz; brak ubrań w selektorze → dodaj rzecz; niekompletny zestaw → lista braków | Błąd zapisu zachowuje edycję; usunięty element → popraw listę; konflikt wersji → Y01 | Kolekcja z cache, lokalny kreator i feedback z etykietą oczekiwania; brak zdjęcia ma etykietę tekstową | Anuluj selektor nie zmienia zestawu; wyjście z edycji pyta o zmiany; po zapisie szczegół; po usunięciu kolekcja |
| F09 Historia i noszenie, H01–H03 | Postęp atomowego zapisu/edycji/cofnięcia; ta sama akcja czeka na wynik | Brak zdarzeń dnia → Dodaj noszenie; przyszła data → Dodaj plan | Przyszła data w formularzu → C02 bez zapisu wear_event; niepewny wynik → sprawdź operację; konflikt → zachowaj wybór i wyjaśnij | Lokalny zapis/edycja/cofnięcie z operation UUID i statusem oczekiwania; widoczny wynik lokalny, bez podwójnego naliczenia retry | Anuluj → dzień źródłowy; potwierdzenie cofnięcia dotyczy jednego zdarzenia; wróć do W02 z zachowaniem filtra |
| F10 CPW i estymacja, H04–H05 | Przeliczenie po zmianie ceny/historii; poprzedni wynik oznaczony jako aktualizowany | Brak ceny / Jeszcze nienoszone; brak estymacji nie jest błędem; akcje dodania ceny/noszenia | Ujemna cena/liczba → pole; nakładanie granicy z historią → jawne rozstrzygnięcie, bez podwójnego sumowania | CPW z lokalnych danych, status oczekujących zmian; edycja ceny/estymacji zachowana do sync | Anuluj edycję → poprzednie wartości; konflikt granicy → popraw lub anuluj; zamknij H05 → źródło |
| F11 Planer, C01–C02 | Ładowanie miesiąca, zapis/przeniesienie planu; brak blokady przejścia do innych dni | Pusty dzień → Dodaj plan; nie ma zestawów → kreator ręczny | Zestaw usunięty/niedostępne rzeczy → lista problemów i wybór zamiany; błąd zapisu → retry tego samego planu | Cache kalendarza i lokalny plan ze statusem oczekiwania; przypomnienie opisane według faktycznego lokalnego zapisu | Anuluj zmianę daty → oryginalny plan; Usuń wymaga potwierdzenia; powrót do właściwego wejścia D01/Z01 |
| F12 Wyjazdy i pakowanie, T01–T03 | Osobno zapis danych i generowanie planu; wyjście nie gubi zadania | Brak wyjazdów → Nowy; brak planu → Uzupełnij dane; brak rzeczy → dodaj/popraw ograniczenia | Data końca przed początkiem → pole; nierealny limit → zmień; awaria generacji → ręczna korekta; utrata Plus → zachowane dane | Zapisana checklista i ręczne zmiany lokalne z oczekiwaniem; generacja zdalna niedostępna; niepobrany wyjazd → połącz i pobierz | Z checklisty → plan → lista → Z01; wyjście z formularza pyta o draft; usuń wyjazd z potwierdzeniem |
| F13 Sprawdzenie zakupu, K01–K02 | Postęp analizy z możliwością opuszczenia; dodawanie do szafy ma osobny zapis | Brak kandydata → Dodaj zdjęcie; brak dopasowań → pokaż braki, bez oceny opłacalności bez danych | Awaria → zachowaj kandydata, retry po sprawdzeniu statusu; odmowa AI → ręczny podgląd i dodanie po zakupie | Lokalny kandydat/poprzedni wynik; brak zdalnego dopasowania; potwierdzony zakup → ręczny lokalny formularz | Anuluj analizę widoku → lista/źródło; Anuluj I03 nie tworzy ubrania; usuń kandydata bez wpływu na istniejące ubrania |
| F14 Powiadomienia i widget, N01–N02 | Odczyt zgody/odświeżanie cache; widget pokazuje ostatni stan z datą | Brak planu → Otwórz planer; brak sesji → Otwórz aplikację; przypomnienia wyłączone → Włącz | Odmowa systemowa → Ustawienia iOS; cel usunięty → informacja i rodzic; zapis przypomnienia nieudany → spróbuj ponownie | Lokalne przypomnienia i widget z cache; noszenie po otwarciu i potwierdzeniu w aplikacji, nigdy sam tap | Zamknij ustawienia → C02/U01; tap widgetu/powiadomienia ma stos rodzica i powrót; logout usuwa cache |
| F15 Kolaż, E01 | „Przygotowuję kolaż”; przycisk share po utworzeniu pliku | Brak wybranych rzeczy → Wybierz zestaw; brak zdjęć → wskaż brak, nie generuj fikcyjnych ubrań | Błąd renderu → Ponów; zdjęcia niedostępne → Pobierz lub wróć; brak potwierdzenia odbioru nie jest sukcesem wysyłki | Render z lokalnych zdjęć; gdy brakuje plików, lista braków i pobranie po odzyskaniu sieci | Anuluj share sheet → podgląd; Zamknij → zestaw/wyjazd; żadne udostępnienie bez świadomego wyboru |
| F16 Statystyki i przegląd, S01–S02 | Odświeżanie po filtrze; etykieta okresu zostaje; brak chwilowych zer podczas ładowania | Brak szafy → Dodaj; brak aktywności w okresie → Zmień okres; brak cen → Uzupełnij, nie wartość 0 całej szafy | Błąd obliczeń/pobrania → zachowany ostatni wynik oznaczony i retry; bez zgadywania wyników | Wyniki z lokalnych danych z czasem sync i oznaczeniem oczekujących zmian | Ranking → W02 → ten sam ranking/okres; powrót z archiwizacji zachowuje filtr i aktualizuje licznik |
| F17 Oferta/zakup/restore, B01–B02 | Produkty → cena dopiero po pobraniu; zakup → system → weryfikacja; restore z osobnym postępem | Brak produktów → „Oferta chwilowo niedostępna”; brak aktywnego zakupu po restore → jasny komunikat | Anulowanie neutralne; pending bez retry zakupu; błąd StoreKit/weryfikacji → sprawdź status/przywróć; refund/revoke/grace/retry według tabeli B02 | Brak nowego zakupu bez StoreKit; ostatnie potwierdzone uprawnienie z datą; restore prosi o połączenie; odczyt danych i ręczne funkcje zostają | Zamknij zawsze wraca do źródła; zarządzanie Apple → B02 po powrocie i odświeżenie; brak automatycznej wysyłki AI po zakupie |
| F18 Profil, zgody, pomoc, U01–U05 | Postęp zapisu profilu/zgody, ładowanie dokumentu; cofnięcie AI od razu zatrzymuje nowe wysyłki lokalne | Brak preferencji/miasta → Dodaj lub zostaw; brak kontaktu w konfiguracji → jawny brak, nie fikcyjny URL | Błąd zapisu zachowuje wybór; błąd dokumentu → retry; nie wysyłaj zgłoszenia bez podglądu; zmiana konta nie przenosi profilu | Preferencje i wyłączenie AI lokalnie z oczekiwaniem; włączenie AI wymaga aktualnych warunków i potwierdzenia przed wysyłką; pomoc z cache z wersją | Anuluj → U01 bez zmiany; polityka → źródło; wylogowanie ostrzega o niewysłanych danych, po potwierdzeniu czyści dane i widget |
| F19 Eksport, X01 | Trwały status kolejka/przygotowanie/pobieranie, można wyjść | Brak danych → wyjaśnij zakres pustego eksportu; brak gotowego eksportu → Przygotuj | Awaria zadania → sprawdź status/ponów bez duplikacji; wygasły link → nowy eksport; wygaśnięta sesja → zaloguj | Brak nowego kompletnego eksportu serwerowego; pokaż ostatni znany status, nie ogłaszaj kompletności lokalnego cache | Powrót → U01; zadanie trwa; anulowanie systemowego zapisu/udostępnienia pliku → X01 |
| F20 Usunięcie konta, X02–X03 | Uwierzytelnienie → przyjęcie → trwałe przetwarzanie; status różny od „Usunięto” | Brak sesji → zaloguj przed żądaniem; potwierdzony brak konta po usunięciu → ekran końcowy z powrotem do O01 | Timeout → sprawdź to samo żądanie; błąd procesu → status i pomoc, bez przywracania danych; nieudane uwierzytelnienie → retry/Anuluj | Wymagane połączenie do przyjęcia; brak automatycznego wysłania destrukcyjnego żądania później; przy trwającym procesie ostatni stan, bez fałszywego sukcesu | Przed finalnym potwierdzeniem Anuluj → U01; po przyjęciu można zamknąć status, bez obietnicy cofnięcia usuwania; zarządzanie Apple nie jest warunkiem |

## Scenariusze przeglądu i późniejszej weryfikacji

Poniższe scenariusze są instrukcją odbioru projektu i przyszłego prototypu/builda.
Nie stanowią dowodu, że wykonano testy na urządzeniu lub sesje z testerami.

| Scenariusz | Oczekiwany wynik projektu / późniejszy punkt kontroli |
| --- | --- |
| Pierwsze otwarcie, pominięcie preferencji i onboarding offline | Lokalny przykład i draft, bez obowiązkowych danych wrażliwych; czytelna droga do D01 oraz późniejszego konta |
| Link email wygasł; Apple private relay; sesja wygasła podczas edycji | Nowy link / obsłużony relay / zachowany draft; powrót do celu po logowaniu tego samego konta |
| Kilka zdjęć, błąd jednego, odmowa aparatu, nieudana segmentacja i AI | Pozostałe drafty postępują, picker i oryginał dostępne, ręczny formularz można zapisać; ostrzeżenie duplikatu można świadomie pominąć |
| Wyszukiwanie bez wyników; pusta szafa; brak sieci podczas paginacji | Trzy różne komunikaty; Wyczyść filtry/Dodaj/Ponów; po powrocie te same filtry i pozycja |
| Dwa urządzenia edytują ubranie; potem usunięcie i zaległa edycja | Konflikt z porównaniem; tombstone nie jest cofany starą edycją; brak cichego nadpisania |
| AI: za mało ubrań, limit, wycofana zgoda, timeout, zmiana dostępności przed zapisem | Braki lub mniej wyników, ręczna alternatywa; brak wysyłki bez zgody; odczyt statusu zadania; ponowna walidacja i zamiana |
| Dwa zestawy z tą samą rzeczą jednego dnia; cofnięcie jednego; retry po timeout | Jeden dzień rzeczy pozostaje; brak zduplikowanego zdarzenia tej samej operacji; historyczna lista niezależna od edycji zestawu |
| Data przyszła i zmiana strefy | Przyszłość przechodzi do planera; stare worn_on pozostaje stałe; plan nie zmienia CPW |
| 800 zł/100 dni, 0 zł z dniami, nieznana cena, brak dni, estymacja z konfliktem granicy | Odpowiednio 8 zł, 0 zł, Brak ceny, Jeszcze nienoszone; estymacja oznaczona i jawnie rozstrzygana |
| Miesięczny filtr statystyk i nowa rzecz bez noszeń | Aktywność dotyczy miesiąca, CPW nadal opisane jako lifetime; nowa rzecz nie trafia do segmentu 90 dni przed upływem okresu |
| Plan wyjazdu, checklista offline, kandydat zakupu i kolaż | Pakowanie nie dodaje noszeń; kandydat nie zwiększa szafy do potwierdzenia; share sheet pokazuje wyłącznie wybrany kolaż |
| Pending, anulowanie, restore bez zakupów, grace, refund i utrata Plus | Osobne komunikaty; dostęp według potwierdzonych uprawnień; podstawowe ręczne funkcje/odczyt/eksport zostają; brak ceny na sztywno |
| Eksport trwa po zamknięciu; usunięcie z aktywną subskrypcją; logout z outboxem | Status eksportu wraca; usunięcie nie wymaga anulowania Apple; ostrzeżenie o niewysłanych danych, cache konta i widgetu wyczyszczone |
| PL/EN, duży Dynamic Type, VoiceOver, Reduce Motion, dark mode | Akcje osiągalne bez zasłonięcia, logiczna kolejność odczytu i tekstowe statusy; sprawdzić w T003 i na docelowym iPhonie, bez uznawania samej dokumentacji za test |

## Pokrycie kryteriów T002

| Kryterium | Dowód w projekcie | Status |
| --- | --- | --- |
| Ekrany onboardingu | O01–O03, A01–A03; projekt §2; F01–F02 | Spełnione w dokumentacji projektu |
| Ekrany szafy | I01–I04, W01–W03, Y01; projekt §3; F03–F05 | Spełnione w dokumentacji projektu |
| Ekrany AI | G01–G03, U03; projekt §4; F06–F08 | Spełnione w dokumentacji projektu |
| Ekrany historii | H01–H05; projekt §5; F09–F10 | Spełnione w dokumentacji projektu |
| Ekrany planera | C01–C02 i T01–T03; projekt §6; F11–F15 | Spełnione w dokumentacji projektu |
| Ekrany statystyk | S01–S02; projekt §7; F16 | Spełnione w dokumentacji projektu |
| Ekrany płatności | B01–B02; projekt §8; F17 | Spełnione w dokumentacji projektu; finalne dane oferty czekają na D01–D03 |
| Ekrany ustawień | U01–U05, X01–X03; projekt §9; F18–F20 | Spełnione w dokumentacji projektu |
| Loading, empty, error, offline i powrót dla każdego przepływu | Każdy wiersz F01–F20 powyżej oraz reguły wspólne | Spełnione w dokumentacji projektu |

Akceptacja finalnego zakresu przez właściciela pozostaje do weryfikacji względem
D01 w T001. Użyteczność prototypu, poprawne zachowanie implementacji i dostępność
na urządzeniu pozostają do sprawdzenia w odpowiednich kolejnych zadaniach.

## Weryfikacja repozytorium

Po zmianach uruchomić:

```sh
export PATH=/home/harness/.local/bin:$PATH && node scripts/harness-check.mjs
```

Harness sprawdza strukturę backlogu i zależności; nie dowodzi jakości UX,
poprawności SwiftUI ani akceptacji właściciela. Dodatkowo sprawdzić
`git diff --check`, lokalne odnośniki obu dokumentów oraz kompletność macierzy
F01–F20. Nie zmieniamy testów ani workflow macOS. Wynik zdalnego CI wymaga
rzeczywistego uruchomienia istniejącego workflow przez harness na GitHubie;
nie jest potwierdzony przez lokalne sprawdzenie na Linuxie.
