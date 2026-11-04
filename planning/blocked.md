# Zablokowane zadania

## T047 — 2026-11-04

- Gałąź / PR: https://github.com/aselwon/moja-szafa-ios/pull/60 (otwarty, NIE zmergowany)
- Co próbowano: harness auto-merge, 3 próba/y
- Ostatni błąd (bez sekretów):

```text
Pull request has merge conflicts; manual resolution is required
```

- Hipoteza: merge odrzucany (konflikt, ochrona gałęzi albo zmiana bazy).
- Pytanie do właściciela: zmergować/poprawić PR ręcznie albo przywrócić `T047` do `todo`.

## T035 — 2026-11-04

- Gałąź / PR: https://github.com/aselwon/moja-szafa-ios/pull/61 (otwarty, NIE zmergowany)
- Co próbowano: harness auto-merge, 3 próba/y
- Ostatni błąd (bez sekretów):

```text
Pull request has merge conflicts; manual resolution is required
```

- Hipoteza: merge odrzucany (konflikt, ochrona gałęzi albo zmiana bazy).
- Pytanie do właściciela: zmergować/poprawić PR ręcznie albo przywrócić `T035` do `todo`.

## T034 — 2026-11-04

- Gałąź / PR: https://github.com/aselwon/moja-szafa-ios/pull/78 (otwarty, NIE zmergowany)
- Co próbowano: harness auto-merge; CI czerwone na 7f6c633
- Ostatni błąd (bez sekretów): CI: failure
- Hipoteza: lokalny `node scripts/harness-check.mjs` przeszedł, CI na GitHubie nie.
- Pytanie do właściciela: poprawić gałąź `task/T034` (nowy push → harness ponownie sprawdzi CI i zmerguje) albo zamknąć PR.
