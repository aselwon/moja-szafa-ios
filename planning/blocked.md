# Zablokowane zadania

## T023 — 2026-11-03

- Gałąź / PR: https://github.com/aselwon/moja-szafa-ios/pull/59 (otwarty, NIE zmergowany)
- Co próbowano: harness auto-merge; CI czerwone na 11c9879
- Ostatni błąd (bez sekretów): CI: failure
- Hipoteza: lokalny `node scripts/harness-check.mjs` przeszedł, CI na GitHubie nie.
- Pytanie do właściciela: poprawić gałąź `task/T023` (nowy push → harness ponownie sprawdzi CI i zmerguje) albo zamknąć PR.
