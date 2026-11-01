# Zablokowane zadania

## T006 — 2026-11-01

- Gałąź / PR: brak (nie wypchnięto)
- Co próbowano: harness, 1 przebieg(i); ostatni błąd poza Codexem
- Ostatni błąd (bez sekretów):

```text
git push -q -u origin task/T006 failed (1):
error: failed to push some refs to 'github-moja-szafa-ios:aselwon/moja-szafa-ios.git'
```

- Hipoteza: Błąd stały (workflow_scope): token/klucz bez uprawnienia `workflow` — GitHub odrzuca zmianę w .github/workflows. Harness nie ponawia — decyzja właściciela.
- Pytanie do właściciela: przejrzeć log `2026-11-01T22-55-52-774Z-moja-szafa-ios-slot-2-T006` i zdecydować: doprecyzować zadanie, podzielić je albo zrobić ręcznie.
