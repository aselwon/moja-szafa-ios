import test from 'node:test';
import assert from 'node:assert/strict';
import { validateRecognition, recognitionDraft } from '../ai/recognition.mjs';
import { createAIExecutor } from '../ai/executor.mjs';

const metadata = { category: 'top', colors: ['blue'], pattern: 'stripes', seasons: ['summer'],
  formality: 2, confidence: 0.8, multiple_items: false };

test('recognition validates closed metadata schema without guessing purchase facts', () => {
  assert.deepEqual(validateRecognition(metadata), metadata);
  for (const key of Object.keys(metadata)) {
    const missing = { ...metadata }; delete missing[key];
    assert.throws(() => validateRecognition(missing), /recognition_invalid/);
  }
  for (const patch of [
    { price: 100 }, { brand: 'Guess' }, { purchased_on: '2026-01-01' }, { requires_correction: false },
    { category: 'shirt' }, { colors: ['navy'] }, { colors: ['blue', 'blue'] }, { colors: 'blue' },
    { pattern: 'invented' }, { seasons: ['all'] }, { seasons: ['summer', 'summer'] },
    { formality: 0 }, { formality: 6 }, { formality: 1.5 }, { formality: '2' },
    { confidence: -0.1 }, { confidence: 1.01 }, { confidence: NaN }, { confidence: Infinity },
    { confidence: '0.9' }, { confidence: null }, { multiple_items: 1 }
  ]) assert.throws(() => validateRecognition({ ...metadata, ...patch }), /recognition_invalid/);
  assert.doesNotThrow(() => validateRecognition({ ...metadata, colors: [], seasons: [], pattern: null, formality: null }));
});

test('all results remain drafts; threshold, ambiguity and multiple garments require review', () => {
  for (const [patch, review] of [[{}, false], [{ confidence: 0.799 }, true], [{ confidence: 0 }, true],
    [{ confidence: 1 }, false], [{ multiple_items: true }, true], [{ category: 'other' }, true]]) {
    const result = recognitionDraft({ ...metadata, ...patch });
    assert.equal(result.state, 'draft');
    assert.equal(result.requires_correction, review);
    assert.equal(result.schema_version, 'garment-recognition-v1');
  }
});

test('executor cannot bypass recognition validation through a permissive runtime hook', async () => {
  for (const mutateHook of [false, true]) {
    const telemetry = [];
    const bad = { ...metadata, brand: 'Invented' };
    const execute = createAIExecutor({
      provider: { recipient: 'fixture', analyzeImage: async () => ({ result: mutateHook ? metadata : bad,
        telemetry: { status: 'success', usage: { input_tokens: 1, output_tokens: 1 } } }), recommendOutfits: async () => {} },
      resolveInput: async () => ({}), authorize: async () => true,
      validateResult: async (_job, value) => mutateHook ? bad : value,
      recordTelemetry: async event => telemetry.push(event)
    });
    assert.deepEqual(await execute({ id: 'fixture', attempt: 1, kind: 'image_analysis' }), { outcome: 'permanent' });
    assert.equal(telemetry[0].status, 'result_rejected');
    assert.equal(telemetry[0].usage.output_tokens, 1);
  }
});
