# Zablokowane zadania

## T022 — 2026-11-03

- Gałąź / PR: https://github.com/aselwon/moja-szafa-ios/pull/50 (otwarty, NIE zmergowany)
- Co próbowano: harness auto-merge; CI czerwone na fd5a9be
- Ostatni błąd (bez sekretów): CI: failure
- Hipoteza: lokalny `node scripts/harness-check.mjs` przeszedł, CI na GitHubie nie.
- Pytanie do właściciela: poprawić gałąź `task/T022` (nowy push → harness ponownie sprawdzi CI i zmerguje) albo zamknąć PR.
