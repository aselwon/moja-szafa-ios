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

## Kontrola zmian

```sh
node scripts/harness-check.mjs
```

Po utworzeniu projektu Xcode CI dodatkowo buduje i testuje schemat `MojaSzafa`
na symulatorze iOS.
