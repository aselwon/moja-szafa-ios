import { createHash } from 'node:crypto';
import { selectCandidates } from '../candidates.mjs';
import { validateOutfits } from '../outfits.mjs';
import { datasetVersion, evaluationCases } from './cases.mjs';

export const digest = value => createHash('sha256').update(JSON.stringify(value)).digest('hex');
export const datasetHash = () => digest(evaluationCases());

// This is the same candidate boundary used by production. Notes are currently
// omitted by selectCandidates: injection cases test that boundary, not model resistance.
export function preparedInput(c) { return selectCandidates(c.input, 'synthetic-owner'); }

export function contractResults() {
  return evaluationCases().map(c => {
    try {
      const input = preparedInput(c);
      if (c.labels.selection_error) throw new Error('unexpected_selection');
      if (input.garments.some(g => c.labels.excluded_ids.includes(g.id))) throw new Error('excluded_candidate');
      const result = validateOutfits(c.labels.reference_response, input);
      if (JSON.stringify(result.outfits[0].missing_categories) !== JSON.stringify(c.labels.missing_categories)) {
        throw new Error('label_mismatch');
      }
      // Mutation probe: an invented/foreign ID must never reach presentation.
      for (const id of ['invented', ...c.labels.excluded_ids]) {
        let rejected = false;
        try { validateOutfits({ outfits: [{ garment_ids: [id], rationale: 'Synthetic probe' }],
          shortfall_reason: 'Synthetic probe' }, input); } catch { rejected = true; }
        if (!rejected) throw new Error('unsafe_acceptance');
      }
      return { id: c.id, passed: true };
    } catch (error) {
      return { id: c.id, passed: !!c.labels.selection_error && error.message === c.labels.selection_error };
    }
  });
}

// Runs are captured elsewhere with explicit authorization. No network or provider
// client exists here. Only aggregates leave this function: never notes/rationales,
// credentials, reviewer identities, paths or arbitrary provider error messages.
export function scoreRun(run, prompt) {
  const cases = evaluationCases();
  const fail = () => { throw new Error('evaluation_run_invalid'); };
  if (run?.dataset_version !== datasetVersion || run.dataset_hash !== datasetHash() ||
      run.prompt_hash !== digest(prompt) || run.prompt_version !== prompt.version ||
      typeof run.model !== 'string' || !/^[a-zA-Z0-9._-]{1,80}$/.test(run.model) ||
      !Array.isArray(run.results) || run.results.length !== cases.length) fail();
  const rows = new Map();
  for (const row of run.results) {
    if (!row || rows.has(row.case_id) || !cases.some(c => c.id === row.case_id) ||
        !['response', 'failed', 'selection_error'].includes(row.status) ||
        (row.usefulness !== undefined && ![0, 1, 2].includes(row.usefulness))) fail();
    rows.set(row.case_id, row);
  }
  const totals = { cases: cases.length, selection_pass: 0, valid_responses: 0, rejected_responses: 0,
    failed: 0, presented_id_violations: 0, reviewed: 0, useful: 0, complete_outfits: 0, presented_outfits: 0 };
  for (const c of cases) {
    const row = rows.get(c.id);
    if (c.labels.selection_error) {
      if (row.status === 'selection_error') totals.selection_pass++; else totals.failed++;
      continue;
    }
    if (row.status !== 'response') { totals.failed++; continue; }
    let output;
    try { output = validateOutfits(row.output, preparedInput(c)); }
    catch { totals.rejected_responses++; continue; }
    totals.valid_responses++;
    for (const outfit of output.outfits) {
      totals.presented_outfits++;
      if (outfit.complete) totals.complete_outfits++;
      if (outfit.garment_ids.some(id => !c.input.garments.some(g => g.id === id &&
          g.user_id === 'synthetic-owner' && g.availability === 'available' && !g.archived))) totals.presented_id_violations++;
    }
    if (row.usefulness !== undefined) { totals.reviewed++; if (row.usefulness === 2) totals.useful++; }
  }
  return totals;
}
