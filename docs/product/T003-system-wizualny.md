# T003 — System wizualny i lokalizacja

Wersja 1.0. System wizualny dla natywnego SwiftUI, zgodny z
[T002](T002-projekt-przeplywow.md) i jego [macierzą stanów](T002-stany-i-odbior.md).
Tokeny i katalog PL/EN są zintegrowane z projektem aplikacji. Wybrane ekrany
przeszły udokumentowane testy layoutu AX5 na symulatorze: [ekrany główne](../quality/T003-core-layout.md),
[formularze i etykiety lokalizowane](../quality/T003-feature-form-layout.md) oraz
[nawigacja](../quality/T003-app-navigation-layout.md). Przebieg prób edycji i eksportu
zdjęć opisuje [osobny raport](../quality/T003-photo-actions.md). Są to wyniki ograniczonych
scenariuszy testowych, nie pełny odbiór dostępności ani test fizycznego urządzenia.

## Źródła i tokeny

[design/tokens.json](../../design/tokens.json) jest kanoniczną paletą i skalą.
Kolory sRGB mają osobne wartości light/dark; bez przezroczystości dla tekstu.
Neutralne tła eksponują prawdziwe zdjęcia. Zielony accent wyróżnia akcję,
nie oznacza automatycznie sukcesu. Motyw domyślnie podąża za systemem.
Tokeny są odwzorowane na named colors w Asset Catalog (Any/Dark).
Nie ustawiaj ręcznie jednego motywu na poziomie aplikacji.

| Rola | Zastosowanie |
| --- | --- |
| background / surface | Tło ekranu / karty, formularze i arkusze |
| primaryText / secondaryText | Treść i tytuły / pomoc oraz metadane |
| accent / onAccent | Wypełnienie głównej akcji / jej tekst; accent także link na surface |
| border | Obramowania pól, kontrolek i wybranego filtra |
| danger | Tekst i ikona błędu, destrukcyjna akcja na surface |
| warning / success | Tekst i ikona ostrzeżenia / potwierdzonego sukcesu na surface |

Kontrola liczy kontrast wszystkich zapisanych par w obu motywach: tekst
minimum 4,5:1, granice kontrolek minimum 3:1. Nie kłaść tekstu bezpośrednio
na zdjęciu; podpis ma nieprzezroczyste surface. Stany zawsze mają tekst
oraz opcjonalną ikonę, nigdy wyłącznie kolor. Increase Contrast zachowuje
co najmniej te same progi. Separatory dekoracyjne nie zastępują granic pól.

Typografia: systemowy SF, semantyczne style SwiftUI z `typography` w tokenach;
żadnych fontów do pobrania. ScreenTitle = largeTitle bold, sectionTitle = title2
semibold, cardTitle = headline, body = body, action = body semibold,
metadata = subheadline, caption = caption. Caption wyłącznie pomocniczo,
nie dla zgód, cen, błędów ani akcji. Wszystkie style skalują się do AX5,
bez limitu Dynamic Type i bez `minimumScaleFactor` jako obejścia układu.
Cena i CPW korzystają z body/title2; cyfry mogą mieć monospacedDigit.

Odstępy: 4/8/12/16/24/32 pt. Margines ekranu 16 pt, odstęp sekcji 24 pt,
padding kart 16 pt, odstęp etykieta–pole 8 pt. Promień kontrolek 12 pt,
kart 16 pt. Minimalny obszar dotyku 44×44 pt, wysokości tekstu są elastyczne.
Brak cieni jako jedynego wyróżnika interakcji. Ikony SF Symbols z tekstem:
Today `sun.max`, Wardrobe `tshirt`, Outfits `square.stack`, Statistics
`chart.bar`; potwierdzić dostępność na minimalnym iOS z D08 w T005.
Ikony dekoracyjne ukryć przed VoiceOver, samodzielne przyciski nazwać.

## Kontrakty komponentów

| Komponent | Wygląd i układ | Stany i dostępność |
| --- | --- | --- |
| PrimaryAction | Pełna szerokość, accent/onAccent, body semibold, padding 16; etykieta wielowierszowa, wysokość minimum 44 | Pressed: obrys, bez zmiany kontrastu. Loading: wskaźnik + czasownik; blokada powtórzenia tylko tej operacji. Disabled: surface/secondaryText z obrysem, jawny powód obok; natywna cecha disabled |
| SecondaryAction / DestructiveAction | Surface, obrys border, tekst accent / danger; ten sam rozmiar dotyku | Destrukcyjna akcja z nazwą skutku i systemowym potwierdzeniem. Anuluj dostępne. Bez fałszywego Cofnij po usunięciu |
| ActionGroup | Kolejność główna → dodatkowe → anulowanie, pionowo przy długich etykietach | Nie umieszczać ważnej akcji wyłącznie w geście swipe. W AX zawsze stos pionowy |
| LabeledField | Etykieta nad natywnym polem, pomoc/błąd pod nim; border, surface | Placeholder nie jest etykietą. Błąd danger + tekst i ikona. Zapis nie kasuje danych. Czytanie: etykieta, wartość, błąd; odpowiednia klawiatura |
| GarmentCard | Zdjęcie aspectFit na surface w proporcji 1:1; pod nim pełna nazwa i dostępność | Brak zdjęcia: symbol + noPhoto; nic fikcyjnego. Dostępność i archiwum osobno. Długi tytuł zwiększa wysokość, nie znika pod badge |
| OutfitCard | Kolaż realnych zdjęć → lista rzeczy → kompletność → uzasadnienie → ActionGroup | Braki opisane tekstem. Zamień przy konkretnej rzeczy z jej nazwą w etykiecie dostępności. Noszenie osobną akcją |
| StatusMessage | Ikona, tytuł, pełny opis, opcjonalna akcja; surface i kolor semantyczny | Empty/error/offline mają różne treści; loading nie udaje pustki. Treść przepływa pionowo. Bez automatycznie znikającego błędu lub jedynej akcji Cofnij w toast |
| Filter / Availability | Natywny picker/lista z zaznaczeniem; długie opcje w arkuszu | Wybór ma znacznik i cechę selected. Nie upychać PL/EN w stałej szerokości segmented control |
| Metric | Etykieta → wartość → zakres/brak danych → szczegóły | CPW lifetime podpisane; noPrice/unworn/estimated z katalogu. Brak nie jest zerem. Bez sumowania CPW |
| Navigation / Sheet | Natywne TabView, stos nawigacji, arkusze; przewijana zawartość | Stałe cztery zakładki T002. Systemowy Back, tekstowe Zamknij/Anuluj. Duży arkusz dla AX, bez zablokowania małej wysokości |

Przypisanie: O01–O03 używają StatusMessage i ActionGroup; I01–I04 pól i kart;
W01–W03 kart, filtrów i destrukcyjnego potwierdzenia; D01/G01–G03/Z01–Z03
OutfitCard; H01–H05/S01–S02 Metric i pól; C01–C02/T01–T03 list i pól;
K01–K02 kart z jawną etykietą kandydata; N01–N02/E01 natywnych kontrolek,
widgetu i share sheet; B01–B02 ActionGroup i StatusMessage; U01–U05,
X01–X03 oraz Y01 pól, list i StatusMessage. Zachowanie każdego stanu pozostaje
zgodne z T002. Apple sign-in i StoreKit używają kontrolek systemowych,
bez własnej imitacji marki lub ceny.

## Układ odporny na długi tekst

Podstawowy ekran: nawigacja → ScrollView/Form → treść → akcje. Nie używać
nakładki `overlay` na dole do głównej akcji. Dla standardowego tekstu dopuszczalny
`safeAreaInset` rezerwujący faktyczne miejsce; przy AX, niskim ekranie lub
wysokiej grupie akcji przenieść całą grupę na koniec tego samego ScrollView.
Nie może powstać footer zajmujący całe okno ani zagnieżdżony pionowy scroll.
Klawiatura zmniejsza dostępny obszar; nie ignorować jej safe area. Pole z focusem,
błąd i akcja muszą być osiągalne przez przewinięcie; systemowe zamknięcie
klawiatury nie może być jedynym sposobem odzyskania przycisku.

- Teksty treści i przycisków: bez limitu linii i stałej wysokości, zawijanie,
  wyrównanie leading; w SwiftUI stosować pionowe dopasowanie rozmiaru tekstu.
- Szafa: kolumny adaptacyjne minimum 152 pt, w AX jedna kolumna; nazwa pod
  zdjęciem. Karta nie ma sztywnej wysokości. W poziomie zachować margines safe area.
- Formularze: etykiety nad polami; pary cena/CPW i porównania konfliktów w AX
  pionowo, z nazwą wersji przy każdej wartości. Nie ścinać uzasadnień ani zgód.
- Kalendarz: przy AX lista dni z pełną datą zamiast zagęszczania siedmiu kolumn.
- Długi niełamliwy identyfikator ma osobny widok szczegółów/kopiowanie;
  nie rozszerza kontenera akcji. Nazwy użytkownika renderować jako tekst, nie klucz.
- VoiceOver: kolejność zgodna z wizualną; nagłówki oznaczone; kolaż ma zwięzły opis,
  a poszczególne rzeczy są dostępne w liście. Komunikat błędu ogłosić raz,
  bez przenoszenia focusu przy każdym odświeżeniu.
- Reduce Motion: bez parallax, pulsowania, przesuwania kart i animowanej zmiany
  wysokości; aktualizacja natychmiastowa. Nie uzależniać informacji od animacji.

## PL/EN i formatowanie

[Localizable.xcstrings](../../design/Localizable.xcstrings) to zintegrowany String
Catalog 1.0, źródłowy język `pl`, ręcznie utrzymywane stabilne klucze i kompletne
odpowiedniki `en`. Obejmuje wspólne komponenty i bazowe teksty wszystkich F01–F20.
Nie jest ukończonym copy wszystkich przyszłych funkcji: nowe teksty dodawać
w ich zadaniach w obu językach. Szczegółowe słowniki kategorii, regulaminy,
odblokowane ceny/limity i treści zgody konkretnego odbiorcy wymagają finalnych
danych; nie zastępować ich przykładowymi obietnicami w produkcji.

Katalog jest dodany do zasobów aplikacji; PL/EN mają ręcznie utrzymywane wpisy.
Walidacja zasobów i testy formularzy potwierdzają pokrycie sprawdzonych kluczy,
ale nie stanowią odbioru wszystkich ekranów. Nie kopiować obok drugiego
Localizable.strings. SwiftUI korzysta z kluczy,
np. `Text("tab.wardrobe")`; nazwy ubrań przez `Text(verbatim:)`.
Teksty spoza SwiftUI korzystają z tej samej tabeli i wybranego locale.
Systemowy język domyślny, PL/EN w ustawieniach zgodnie z T002; wybór musi objąć
zarówno SwiftUI, jak i formatery. Brak obsługi innego języka → polski fallback.
Nie tłumaczyć danych użytkownika i nie zmieniać zapisanych dni historycznych.

Nie sklejać zdań z fragmentów. `wardrobe.count` i `wear.days` zawierają warianty
PL one/few/many/other oraz EN one/other z argumentem Int64 `%lld`;
`sync.lastUpdated` przyjmuje sformatowaną datę/czas `%@`. Przy integracji użyć
formatowania lokalizowanego obsługującego plural, nie zwykłego zastąpienia tekstu.
Testować 0, 1, 2, 5, 12, 22, 25, 101, 112. Dni i liczby nie są tekstem AI.

Ceny szafy przechowywane w groszach, prezentowane z Decimal i formatowaniem
waluty PLN dla wybranego języka; bez float i bez automatycznej konwersji walut.
Ceny subskrypcji wyłącznie StoreKit. Daty przez lokalizowane formatery;
worn_on to dzień kalendarzowy bez przesuwania historycznej daty przez timezone.
Nie wpisywać formatu daty i separatorów liczbowych w tłumaczeniu.

## Odbiór i granice dowodów

`node scripts/harness-check.mjs` sprawdza schemat tokenów, kontrast,
kompletność PL/EN, plural i zgodność argumentów. To kontrola zasobów, nie
kompilacja xcstrings ani dowód poprawnego layoutu. Zadanie CI `validate`
uruchamia tę kontrolę; osobne zadania macOS budują i testują aplikację.

Udokumentowane próby AX5 obejmują wybrane ekrany główne, formularze i trasy
nawigacji w PL/EN oraz light/dark na iOS 27.2 Simulator. Pełna macierz poniżej
nadal opisuje wymagania pozostające do odbioru; nie należy traktować jej jako
wykonanej na podstawie tych ograniczonych testów. Zachowuj model, iOS, wersję
buildu, locale, rozmiar tekstu, zrzuty i wynik każdej nowej próby.

| Próba | Oczekiwany wynik / dowód |
| --- | --- |
| PL i EN × light/dark × domyślny tekst i AX5, pion i poziom | W01, I03, G03, B01, X02: pełne teksty, akcje dostępne po scrollu, brak kolizji. Zrzuty każdego wariantu |
| Nazwa rzeczy 200 znaków, opis 1000, etykieta akcji wydłużona dwukrotnie | W02/G03: zawijanie bez ścinania i skalowania fontu; można aktywować każdą akcję |
| I03 z klawiaturą i błędem ceny, X02 z długim ostrzeżeniem | Pole, błąd, Zapisz/Anuluj oraz Usuń dostępne, focus nie zasłonięty; nie trzeba zmniejszać tekstu |
| VoiceOver, Bold Text, Increase Contrast, Reduce Motion | Logiczny odczyt, nazwane kontrolki, touch ≥44 pt, informacja niezależna od koloru/ruchu; nagranie lub raport |
| PL/EN plural dla podanych liczb; zmiana języka | Poprawna odmiana, bez surowych kluczy/placeholderów; PLN nie zmienia się w walutę subskrypcji |
| Loading/empty/error/offline i długi opis z T002 | Retry/powrót dostępne, draft zachowany, brak fałszywego sukcesu; sprawdzić w obu motywach |

Stan: definicje i zasoby są zintegrowane. Udokumentowane testy potwierdzają
dostępność wybranych akcji w konkretnych scenariuszach AX5; nie potwierdzają
pełnej macierzy ekranów, orientacji i stanów. Pozostają między innymi VoiceOver,
fizyczne urządzenie, najmniejszy wspierany ekran, formularz z klawiaturą i błędem,
Increase Contrast, Bold Text oraz Reduce Motion w pełnej macierzy dostępności
T057. Wyniki T003 nie zastępują tego osobnego odbioru.
