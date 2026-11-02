# Zablokowane zadania

## T010 — 2026-11-02

- Gałąź / PR: https://github.com/aselwon/moja-szafa-ios/pull/14 (otwarty, NIE zmergowany)
- Co próbowano: harness auto-merge; CI czerwone na 9985d57
- Ostatni błąd (bez sekretów): CI: failure
- Hipoteza: lokalny `node scripts/harness-check.mjs` przeszedł, CI na GitHubie nie.
- Pytanie do właściciela: poprawić gałąź `task/T010` (nowy push → harness ponownie sprawdzi CI i zmerguje) albo zamknąć PR.
