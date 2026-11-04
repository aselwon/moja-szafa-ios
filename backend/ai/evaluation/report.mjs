import { readFile, writeFile } from 'node:fs/promises';
import { pathToFileURL } from 'node:url';
import { resolve } from 'node:path';
import { baseline, candidate } from './prompts.mjs';
import { contractResults, datasetHash, digest, scoreRun } from './evaluate.mjs';
import { datasetVersion, families } from './cases.mjs';

export function comparisonReport(runs) {
  const results = contractResults();
  if (results.some(r => !r.passed)) throw new Error('evaluation_contract_failed');
  if (runs && (runs.length !== 2 || runs[0]?.model !== runs[1]?.model)) throw new Error('evaluation_pair_invalid');
  const scores = runs ? [scoreRun(runs[0], baseline), scoreRun(runs[1], candidate)] : null;
  // Deliberately do not interpolate anything from imported run metadata or outputs.
  const rows = [baseline, candidate].map((prompt, index) => {
    const s = scores?.[index];
    return `| ${prompt.version} | ${digest(prompt)} | ${s ? `${s.valid_responses}/110` : 'Not run'} | ${s ? s.rejected_responses : 'Not run'} | ${s ? s.failed : 'Not run'} | ${s ? s.presented_id_violations : 'Not measured'} | ${s ? `${s.useful}/${s.reviewed} reviewed` : 'Not reviewed'} |`;
  });
  return `# T033 AI evaluation report

Dataset: ${datasetVersion}; SHA-256: ${datasetHash()}.

120 original synthetic text contexts; no photos, personal data or third-party assets.
Each of the ${families.length} families contains 10 cases: ${families.join(', ')}.
Cases vary requested count (1–10), clothing composition and occasion formality.
These are correlated regression fixtures, not 120 independent real-world observations.

## Local contract verification

${results.filter(r => r.passed).length}/${results.length} cases pass selection, reference-label checks and invented/excluded-ID rejection probes (where selection succeeds).
These results exercise deterministic code, not model quality or prompt effectiveness.
10 empty-wardrobe cases stop before the provider; 110 cases can receive model responses.

## Paired prompt comparison

| Prompt | SHA-256 (version and text) | Valid responses | Rejected responses | Failed cases | Presented ID violations | Human usefulness |
| --- | --- | --- | --- | --- | --- | --- |
${rows.join('\n')}

The baseline is the production prompt. The candidate adds explicit preference-conflict and winter-layer guidance; it is not enabled in production. Both use the same dataset and server validation. No improvement is claimed without paired responses. Category accuracy is not measurable with this text-only suite.

${scores ? `Observed valid-response delta (candidate minus baseline): ${scores[1].valid_responses - scores[0].valid_responses}. Empty-wardrobe selection passes: baseline ${scores[0].selection_pass}/10; candidate ${scores[1].selection_pass}/10.` : 'No provider calls or human reviews were performed. Model quality, latency, cost and the >=80% usefulness gate remain unmeasured.'}

## Limitations and next verification

Run the paired protocol in README.md with an authorized model and budget, review all responses blind, and regenerate this report. Verify zero ownership/nonexistent-ID violations in presented results; inspect rejected responses separately. Recognition requires a separate rights-cleared labeled photo set and the >=90% category gate. No image-classification evidence is claimed here.

Notes are currently removed by production candidate selection. Injection cases verify this boundary; they do not demonstrate model resistance to instructions embedded in photos or future note-enabled prompts. Weather is represented by season metadata, not a live forecast.
`;
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  try {
    const args = process.argv.slice(2);
    if (![0, 2].includes(args.length)) throw new Error('evaluation_arguments_invalid');
    const runs = args.length ? await Promise.all(args.map(async path => JSON.parse(await readFile(path, 'utf8')))) : undefined;
    await writeFile(new URL('../../../docs/verification/T033-ai-evaluation.md', import.meta.url), comparisonReport(runs));
    console.log('AI evaluation report written (aggregate data only).');
  } catch {
    console.error('AI evaluation failed: check local inputs against the documented contract.');
    process.exitCode = 1;
  }
}
