# Moja Szafa iOS

Natywna aplikacja iPhone do katalogowania ubrań, układania stylizacji,
planowania noszenia i obliczania cost per wear.

Zakres wydania i wymagania produktu znajdują się w [SPEC.md](SPEC.md), a
kanoniczna kolejka prac dla harnessu w [planning/tasks.json](planning/tasks.json).

## Kontrola zmian

```sh
node scripts/harness-check.mjs
```

Po utworzeniu projektu Xcode CI dodatkowo buduje i testuje schemat `MojaSzafa`
na symulatorze iOS.
