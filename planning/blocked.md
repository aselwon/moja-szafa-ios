# Zablokowane zadania

## T009 — 2026-11-01

- Gałąź / PR: https://github.com/aselwon/moja-szafa-ios/pull/10 (otwarty, NIE zmergowany)
- Co próbowano: harness auto-merge; CI czerwone na 377249f
- Ostatni błąd (bez sekretów): CI: failure
- Hipoteza: lokalny `node scripts/harness-check.mjs` przeszedł, CI na GitHubie nie.
- Pytanie do właściciela: poprawić gałąź `task/T009` (nowy push → harness ponownie sprawdzi CI i zmerguje) albo zamknąć PR.
