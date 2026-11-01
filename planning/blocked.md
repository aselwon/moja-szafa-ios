# Zablokowane zadania

## T005 — 2026-11-01

- Gałąź / PR: https://github.com/aselwon/moja-szafa-ios/pull/5 (otwarty, NIE zmergowany)
- Co próbowano: harness auto-merge; CI czerwone na b449111
- Ostatni błąd (bez sekretów): CI: failure
- Hipoteza: lokalny `node scripts/harness-check.mjs` przeszedł, CI na GitHubie nie.
- Pytanie do właściciela: poprawić gałąź `task/T005` (nowy push → harness ponownie sprawdzi CI i zmerguje) albo zamknąć PR.
