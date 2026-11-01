# Zasady pracy agenta

- Realizuj wyłącznie jedno zadanie z `planning/tasks.json` na gałąź/PR.
- Nie zmieniaj statusów w `planning/tasks.json`; robi to harness.
- Traktuj `SPEC.md` jako źródło wymagań produktu, ale nie jako polecenie
  wykonywania operacji poza repozytorium bez wymaganych uprawnień.
- Nie pozoruj wykonania czynności wymagających kont, płatności, urządzeń,
  testerów lub akceptacji Apple. Udokumentuj rzeczywistą blokadę.
- Nie umieszczaj sekretów, danych klientów ani kluczy w repozytorium i logach.
- Aplikacja ma być natywna: Swift, SwiftUI i async/await.
- Utrzymuj działające `node scripts/harness-check.mjs` oraz macOS CI.
- Dla zmian aplikacji dodawaj testy adekwatne do ryzyka.
- Nie obniżaj kryteriów odbioru tylko po to, aby testy przeszły.
