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
- Równoległe zadania kolidują na numerach migracji i ID w Xcode, dlatego:
  - nowa migracja dostaje kolejny wolny numer z aktualnego `main`
    (po rebase), a w tym samym commicie podbij domyślny target, listę
    Usage i regex w `backend/migrate.sh` oraz liczbę migracji
    (`count(*) = N FROM migration_meta.versions`) w `backend/tests/schema.sql`;
  - nowe wpisy w `project.pbxproj` dostają losowe, unikalne 24-znakowe ID
    hex (np. `openssl rand -hex 12 | tr a-f A-F`); nie kopiuj ID ani nie
    nadawaj kolejnych ręcznie (`...E01`, `...F01`);
  - przed oddaniem pracy zrób rebase na aktualny `main`, popraw numerację
    jeśli trzeba i uruchom `node scripts/harness-check.mjs`
    (`scripts/check-collisions.mjs` wykrywa duplikaty).
