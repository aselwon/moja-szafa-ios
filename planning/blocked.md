# Zablokowane zadania

## T005 — 2026-11-01

- Gałąź / PR: https://github.com/aselwon/moja-szafa-ios/pull/5 (otwarty, NIE zmergowany)
- Co próbowano: harness dociągnął `main` do gałęzi 7 raz(y); CI dalej czerwone
- Ostatni błąd (bez sekretów): CI PR czerwone (szczegóły w checkach PR).
- Hipoteza: błąd jest w kodzie gałęzi zadania, nie w bazie.
- Pytanie do właściciela: poprawić gałąź `task/T005` albo zamknąć PR i przywrócić `T005` do `todo`.

## T008 — 2026-11-01

- Gałąź / PR: brak (nie wypchnięto)
- Co próbowano: harness, 1 przebieg(i); ostatni błąd poza Codexem
- Ostatni błąd (bez sekretów):

```text
git push -q -u origin task/T008 failed (1):
error: failed to push some refs to 'github-moja-szafa-ios:aselwon/moja-szafa-ios.git'
```

- Hipoteza: Błąd stały (workflow_scope): token/klucz bez uprawnienia `workflow` — GitHub odrzuca zmianę w .github/workflows. Harness nie ponawia — decyzja właściciela.
- Pytanie do właściciela: przejrzeć log `2026-11-01T20-28-09-840Z-moja-szafa-ios-T008` i zdecydować: doprecyzować zadanie, podzielić je albo zrobić ręcznie.
