import test from 'node:test';
import assert from 'node:assert/strict';
import { validateOutfits } from '../ai/outfits.mjs';
import { selectCandidates } from '../ai/candidates.mjs';
import { createProvider, serverConfiguration } from '../ai/provider.mjs';
import { createAIExecutor } from '../ai/executor.mjs';

const garments = ['top', 'bottom', 'shoes', 'dress', 'jumpsuit'].map(id => ({ id, category: id,
  user_id: 'owner', availability: 'available', archived: false }));
const input = { garments, count: 1 };
const result = (ids, reason = null) => ({ outfits: [{ garment_ids: ids, rationale: 'Suggested outfit.' }], shortfall_reason: reason });

test('count defaults to three and accepts only integers 1–10', () => {
  assert.equal(selectCandidates({ garments }, 'owner').count, 3);
  for (const count of [1, 10]) assert.equal(selectCandidates({ garments, count }, 'owner').count, count);
  for (const count of [null, 0, 11, 1.5, '3']) assert.throws(() => selectCandidates({ garments, count }, 'owner'));
});

test('server computes completeness and explicitly labels incomplete outfits', () => {
  for (const ids of [['top', 'bottom', 'shoes'], ['dress', 'shoes'], ['jumpsuit', 'shoes']]) {
    const outfit = validateOutfits(result(ids), input).outfits[0];
    assert.equal(outfit.complete, true);
    assert.deepEqual(outfit.missing_categories, []);
  }
  const outfit = validateOutfits(result(['top']), input).outfits[0];
  assert.equal(outfit.complete, false);
  assert.deepEqual(outfit.missing_categories, ['bottom', 'shoes']);
});

test('strict schema, known IDs, pin and requested maximum fail closed', () => {
  for (const value of [null, [], {}, result([]), result(['foreign']), result(['top', 'top']),
    { ...result(['top']), extra: true }, { ...result(['top']), outfits: [{ garment_ids: ['top'], rationale: '' }] },
    { outfits: [], shortfall_reason: null }, { outfits: [result(['top']).outfits[0], result(['dress']).outfits[0]], shortfall_reason: null }]) {
    assert.throws(() => validateOutfits(value, input));
  }
  assert.throws(() => validateOutfits(result(['dress', 'shoes']), { ...input, pinned_garment_id: 'top' }));
});

test('deduplication ignores order and every shortfall has an explanation', () => {
  const value = result(['top', 'bottom', 'shoes']);
  value.outfits.push({ garment_ids: ['shoes', 'bottom', 'top'], rationale: 'Repeated.' });
  const output = validateOutfits(value, { ...input, count: 2 });
  assert.equal(output.outfits.length, 1);
  assert.match(output.shortfall_reason, /Duplicate/);
  assert.equal(validateOutfits({ outfits: [], shortfall_reason: 'No suitable combination.' }, input).outfits.length, 0);
  assert.throws(() => validateOutfits(result(['top']), { ...input, count: 3 }));
  const ten = { outfits: Array.from({ length: 10 }, (_, i) => ({ garment_ids: [`top-${i}`, 'shoes', 'bottom'], rationale: 'Distinct.' })), shortfall_reason: null };
  assert.equal(validateOutfits(ten, { count: 10, garments: [...garments, ...Array.from({ length: 10 }, (_, i) => ({ id: `top-${i}`, category: 'top' }))] }).outfits.length, 10);
});

function fixture(contents, { revoke = false, change = false } = {}) {
  let calls = 0, auth = 0, resolves = 0;
  const telemetry = [];
  const provider = createProvider(serverConfiguration({ AI_ENDPOINT: 'https://fixture.invalid', AI_PROVIDER: 'fixture',
    AI_RECIPIENT: 'fixture', AI_API_KEY: 'synthetic', AI_IMAGE_MODEL: 'image', AI_OUTFIT_MODEL: 'outfit' }), {
    fetchImpl: async (_url, request) => {
      const body = JSON.parse(request.body);
      if (calls === 1) assert.match(body.messages[1].content, /previous response was invalid JSON/);
      const content = contents[Math.min(calls++, contents.length - 1)];
      if (content === 'HTTP') return new Response('', { status: 503 });
      return Response.json({ model: 'outfit', usage: { prompt_tokens: 2, completion_tokens: 3 },
        choices: [{ finish_reason: 'stop', message: { content } }] });
    }
  });
  const execute = createAIExecutor({ provider,
    resolveInput: async () => ({ ...input, garments: change && resolves++ > 0 ? garments.filter(g => g.id !== 'top') : garments }),
    authorize: async () => !(revoke && auth++ > 0),
    validateResult: async (_job, value) => value,
    recordTelemetry: async value => telemetry.push(value) });
  return { run: () => execute({ id: 'job', attempt: 1, kind: 'outfit_generation', user_id: 'owner' }), telemetry, calls: () => calls };
}

test('invalid JSON gets exactly one repair with separately accounted usage', async () => {
  const f = fixture(['not JSON', JSON.stringify(result(['top', 'bottom', 'shoes']))]);
  assert.equal((await f.run()).outcome, 'success');
  assert.equal(f.calls(), 2);
  assert.deepEqual(f.telemetry.map(t => t.provider_call), [1, 2]);
  assert.deepEqual(f.telemetry.map(t => t.usage), [{ input_tokens: 2, output_tokens: 3 }, { input_tokens: 2, output_tokens: 3 }]);
});

test('repair is bounded; HTTP/domain failures never retry; revoked consent prevents repair', async () => {
  for (const [contents, options, expected] of [
    [['bad JSON'], {}, 2], [['HTTP'], {}, 1], [[JSON.stringify(result(['foreign']))], {}, 1],
    [['bad JSON'], { revoke: true }, 1],
    [['bad JSON', JSON.stringify(result(['top', 'shoes']))], { change: true }, 2]
  ]) {
    const f = fixture(contents, options);
    assert.equal((await f.run()).outcome, 'permanent');
    assert.equal(f.calls(), expected);
  }
});
