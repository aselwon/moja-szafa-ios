# Moja Szafa iOS

Natywna aplikacja iPhone do katalogowania ubrań, układania stylizacji,
planowania noszenia i obliczania cost per wear.

Zakres wydania i wymagania produktu znajdują się w [SPEC.md](SPEC.md), a
kanoniczna kolejka prac dla harnessu w [planning/tasks.json](planning/tasks.json).

Macierz Free/Plus, rynek startowy i rejestr decyzji właściciela dla T001 znajdują
się w [specyfikacji produktu 1.0](docs/product/T001-specyfikacja-produktu.md).

Projekt układów ekranów, nawigacji i przepływów T002 znajduje się w
[projekcie UX](docs/product/T002-projekt-przeplywow.md), a stany loading, empty,
error, offline i powroty w [macierzy stanów i odbioru](docs/product/T002-stany-i-odbior.md).

System wizualny T003, kontrakty komponentów i macierz weryfikacji dostępności
opisuje [specyfikacja wizualna](docs/product/T003-system-wizualny.md).
Zasoby do integracji w T005: [tokeny](design/tokens.json) oraz
[String Catalog PL/EN](design/Localizable.xcstrings).

Warunkowy wybór backendu T007, region, model kosztów i trwałość zadań opisuje
[ADR-001](docs/architecture/ADR-001-backend.md). Konfigurację do wykonania po
autoryzacji i wymagane dowody zawiera [procedura staging](docs/operations/T007-staging.md).
Staging nie został wdrożony; aktualność dokumentacji i kosztów wymaga weryfikacji.

## Kontrola zmian

```sh
node scripts/harness-check.mjs
```

Po utworzeniu projektu Xcode CI dodatkowo buduje i testuje schemat `MojaSzafa`
na symulatorze iOS.

## Projekt iOS (T005)

Otwórz `MojaSzafa.xcodeproj`, wybierz schemat `MojaSzafa` i symulator iPhone.
Baza techniczna: Xcode 16.4, Swift 6, iOS 17+ (do zatwierdzenia w D08).
[Architektura i instrukcja czystego buildu](docs/architecture/T005-ios-foundation.md)
opisują DI, repozytoria, testy i ograniczenia weryfikacji.
Aplikacja nie ma jeszcze połączenia z backendem: jawnie pokazuje ten stan,
a dane demonstracyjne występują wyłącznie w testach.
