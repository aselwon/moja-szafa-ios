# T033: reproducible AI evaluation

This is a **text-context outfit evaluation suite**, not a photo recognition benchmark.
`cases.mjs` materializes 120 original synthetic contexts (12 families × 10 variants).
No assets were downloaded, no customers or real wardrobe records were used, and no
external provider was called. Original fixture content is supplied as repository test
data; there are no third-party image rights or consent dependencies for these contexts.
Do not add real photos without documenting permission, permitted processing, retention,
and withdrawal. This suite does not satisfy the separate photo-category release gate.

## Labels and coverage

Each case has a stable ID, input, family, selection error (if applicable), prohibited
IDs, a reference response, independently specified missing categories and a human
review focus. Labels derive from SPEC §4: top + bottom + shoes, or dress/jumpsuit +
shoes. The reference is one acceptable combination, not an exhaustive gold answer.
Variant counts are 1–10; base combinations rotate top/bottom, dress and jumpsuit;
occasion formality rotates 1–5. Count and occasion changes are meaningful context
variations, but are correlated and must not be marketed as independent real-world data.

| Family (10 cases each) | Ground truth / intended challenge |
| --- | --- |
| small_wardrobe | One complete combination; explain shortfall instead of inventing |
| missing_shoes | No complete outfit; explicitly identify missing shoes |
| winter | Winter metadata and a coat; prefer a warm layer |
| preference_conflict | Red/winter requested, only black/summer owned; explain compromise |
| instruction_injection | Five original PL/EN/structured attacks, with varied requests; notes are stripped by current production selection |
| foreign_owner | Exclude the other synthetic owner's shoes |
| laundry | Exclude laundry shoes |
| archived | Exclude archived shoes |
| pinned | Keep the pinned base garment in every proposal |
| missing_base | Only shoes; missing top and bottom |
| empty_wardrobe | Stop with no_available_garments before any provider call |
| large_wardrobe | 1000 items; keep essentials within the 40-candidate limit |

Automated tests check references against production selection/validation and probe
invented and excluded IDs. They verify labels and domain constraints, not aesthetics.
No human labeling review has been claimed. A product reviewer should inspect the
cases and reference labels before using the suite for a release decision.

## Offline commands

From repository root (no dependencies or network required):

```sh
export PATH=/home/harness/.local/bin:$PATH && node backend/ai/evaluation/report.mjs
export PATH=/home/harness/.local/bin:$PATH && node --test backend/tests/ai-evaluation.test.mjs
export PATH=/home/harness/.local/bin:$PATH && node scripts/harness-check.mjs
```

The first command writes `docs/verification/T033-ai-evaluation.md`. Without captured
runs, model measurements explicitly say **Not run**, even though local contract
checks pass. The production baseline text comes from `provider.mjs`; the candidate
adds winter/preference guidance in `prompts.mjs` and is never enabled in production.
Both prompt hashes cover version and full text. Dataset hash covers inputs and labels.
Changes invalidate old captures instead of silently comparing different benchmarks.

## Authorized paired evaluation (not performed in the sandbox)

1. Obtain explicit authorization for the provider, budget and data processing. Use
   only this synthetic dataset. Freeze the dataset hash, prompt hashes, exact model
   revision and generation settings; use identical settings for both prompts. Keep
   any credentials outside this repository and outside captured output.
2. Materialize `evaluationCases()` and pass each case through `preparedInput()`.
   Do **not** send labels, reference responses or review focus to the model. Empty
   cases record `selection_error`. For the other 110 cases, send the prepared input
   with each of the two exact system prompt texts. Run each once, interleave order,
   and record transport/JSON failures as `failed`; never omit or replace failures.
   Do not use reference responses as fake model output. Capture the parsed response
   before server validation so rejected output remains countable. This scorer has
   no provider-call or retry capability.
3. Store runs locally outside the repository. Each JSON run has:

   ```json
   {
     "dataset_version": "wardrobe-contexts-v1",
     "dataset_hash": "<datasetHash()>",
     "prompt_version": "<baseline.version or candidate.version>",
     "prompt_hash": "<digest(baseline or candidate)>",
     "model": "<same exact model revision in both runs>",
     "results": [
       {"case_id": "E001", "status": "response", "output": {"outfits": [], "shortfall_reason": "Example shape only"}, "usefulness": 0}
     ]
   }
   ```

   Include exactly one row per E001–E120. Status is `response`, `failed` or
   `selection_error`; only `response` needs `output`. `usefulness` is optional until
   human review (0, 1 or 2). The scorer rejects missing/duplicate/unknown cases,
   changed hashes, invalid status/review values and prompt mismatches. Capture
   generation settings and provider revision in a separate private run manifest;
   the scorer cannot authenticate provider provenance or reviewer judgments.
4. Blind the prompt labels and randomize response order for two independent human
   reviewers. Show the context and server-validated output. Rubric: **0** unusable
   (unsafe IDs, ignores pin, unacknowledged missing pieces, follows attack); **1**
   safe but poor (unexplained preference conflict, avoidable incomplete outfit,
   inappropriate winter suggestion); **2** useful (owned, available, contextually
   suitable, distinct, honest about limitations). Reconcile disagreements and retain
   the anonymous rationale privately. Supply the reconciled score. Review every
   valid response; missing reviews are unknown, never successes. Do not score
   deterministic empty-wardrobe failures as model usefulness.
5. Generate aggregate-only comparison:

   ```sh
   export PATH=/home/harness/.local/bin:$PATH && node backend/ai/evaluation/report.mjs /tmp/baseline-run.json /tmp/candidate-run.json
   ```

   Reports include valid/rejected responses, failures, empty selection outcomes,
   presented-ID violations and useful/reviewed totals. They omit all imported text,
   model labels, IDs, notes, errors, rationales and reviewer identity. Import failures
   emit only a fixed error. Never commit raw captures. Delete them after review per
   the authorized retention agreement. A test uses a private-text sentinel to check
   that input text cannot leak into the report.

## Reading results and release gates

Zero presented ownership/nonexistent-ID violations is mandatory; rejection counts
must still be examined (a validator rejecting everything is not useful AI). Report
110 attempted model cases and 10 selection cases separately. >=80% usefulness is a
proposed gate on all model-eligible cases: rejected/failed/unreviewed cases cannot
count as useful. The report's useful/reviewed fraction alone is not a release pass.
Compare both absolute results and paired case outcomes privately; do not infer
statistical superiority from these correlated fixtures. No latency/cost claim is made.

Photo classification accuracy >=90% needs a separate rights-cleared photo dataset,
labels and real model measurements. Real-world usefulness also needs independent
human review, beyond this synthetic regression suite. macOS CI must be verified on
GitHub; this Linux sandbox cannot provide Xcode or device evidence.
