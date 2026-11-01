# Zablokowane zadania

## T005 — 2026-11-01

- Gałąź / PR: https://github.com/aselwon/moja-szafa-ios/pull/5 (otwarty, NIE zmergowany)
- Co próbowano: harness auto-merge; CI czerwone na 107b6f1
- Ostatni błąd (bez sekretów): CI: failure
- Hipoteza: lokalny `node scripts/harness-check.mjs` przeszedł, CI na GitHubie nie.
- Pytanie do właściciela: poprawić gałąź `task/T005` (nowy push → harness ponownie sprawdzi CI i zmerguje) albo zamknąć PR.

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
