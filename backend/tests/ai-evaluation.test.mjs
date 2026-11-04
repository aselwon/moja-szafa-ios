import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { evaluationCases, families, datasetVersion } from '../ai/evaluation/cases.mjs';
import { contractResults, preparedInput, digest, datasetHash, scoreRun } from '../ai/evaluation/evaluate.mjs';
import { baseline, candidate } from '../ai/evaluation/prompts.mjs';
import { comparisonReport } from '../ai/evaluation/report.mjs';

const cases = evaluationCases();
const fixtureRun = prompt => ({ dataset_version: datasetVersion, dataset_hash: datasetHash(),
  prompt_version: prompt.version, prompt_hash: digest(prompt), model: 'synthetic-test-only',
  results: cases.map(c => ({ case_id: c.id, status: c.labels.selection_error ? 'selection_error' : 'response',
    output: structuredClone(c.labels.reference_response), usefulness: 2 })) });

test('120 reproducible labeled contexts cover all required families and reference invariants', () => {
  assert.equal(cases.length, 120);
  assert.equal(new Set(cases.map(c => c.id)).size, 120);
  assert.equal(new Set(cases.map(c => digest(c.input))).size, 120);
  assert.deepEqual(evaluationCases(), cases);
  for (const family of families) assert.equal(cases.filter(c => c.family === family).length, 10);
  assert.ok(contractResults().every(r => r.passed));
  for (const c of cases.filter(c => !c.labels.selection_error)) {
    const selected = preparedInput(c);
    assert.ok(selected.garments.length <= 40);
    if (c.input.pinned_garment_id) assert.ok(selected.garments.some(g => g.id === c.input.pinned_garment_id));
    assert.equal(selected.notes, undefined);
  }
});

test('scoring distinguishes rejection, failure, review and server presentation', () => {
  const run = fixtureRun(baseline);
  const good = scoreRun(run, baseline);
  assert.equal(good.valid_responses, 110);
  assert.equal(good.selection_pass, 10);
  assert.equal(good.presented_id_violations, 0);
  run.results[0].output.outfits[0].garment_ids = ['invented'];
  run.results[1].status = 'failed';
  delete run.results[2].usefulness;
  const scored = scoreRun(run, baseline);
  assert.equal(scored.valid_responses, 108);
  assert.equal(scored.rejected_responses, 1);
  assert.equal(scored.failed, 1);
  assert.equal(scored.reviewed, 107);
});

test('reject missing/duplicate/unknown cases, mismatched datasets and prompts, invalid reviews', () => {
  for (const mutate of [r => r.results.pop(), r => { r.results[1] = r.results[0]; },
    r => { r.results[0].case_id = 'unknown'; }, r => { r.dataset_hash = 'wrong'; },
    r => { r.prompt_hash = 'wrong'; }, r => { r.prompt_version = candidate.version; },
    r => { r.results[0].usefulness = 3; }, r => { r.results[0].status = 'unknown'; }]) {
    const run = fixtureRun(baseline); mutate(run);
    assert.throws(() => scoreRun(run, baseline), /evaluation_run_invalid/);
  }
});

test('reports never copy imported text or arbitrary metadata', () => {
  const runs = [fixtureRun(baseline), fixtureRun(candidate)];
  const sentinel = 'PRIVATE-SENTINEL-DO-NOT-PRINT';
  for (const run of runs) {
    run.private_metadata = sentinel;
    run.model = sentinel;
    for (const row of run.results) {
      row.error = sentinel;
      for (const outfit of row.output.outfits) outfit.rationale = sentinel;
    }
  }
  assert.ok(!comparisonReport(runs).includes(sentinel));
  assert.match(comparisonReport(), /Not run/);
});

test('checked-in report fingerprints match dataset and production prompt', async () => {
  const report = await readFile(new URL('../../docs/verification/T033-ai-evaluation.md', import.meta.url), 'utf8');
  assert.ok(report.includes(datasetHash()));
  assert.ok(report.includes(digest(baseline)));
  assert.ok(report.includes(digest(candidate)));
});

test('paired comparison rejects different model revisions', () => {
  const runs = [fixtureRun(baseline), fixtureRun(candidate)];
  runs[1].model = 'different-model';
  assert.throws(() => comparisonReport(runs), /evaluation_pair_invalid/);
});
