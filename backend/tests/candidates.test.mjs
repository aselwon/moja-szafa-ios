import test from 'node:test';
import assert from 'node:assert/strict';
import { selectCandidates, candidateLimit } from '../ai/candidates.mjs';
import { createAIExecutor } from '../ai/executor.mjs';
import { createProvider, serverConfiguration } from '../ai/provider.mjs';

const garment = (id, category = 'top', extra = {}) => ({ id, category, user_id: 'owner',
  availability: 'available', archived: false, ...extra });
const select = (garments, extra = {}) => selectCandidates({ garments, count: 3, ...extra }, 'owner');

test('ownership and explicit availability fail closed, including pins', () => {
  const garments = [garment('yes'), garment('foreign', 'shoes', { user_id: 'another' }),
    garment('laundry', 'shoes', { availability: 'laundry' }), garment('absent', 'shoes', { availability: 'unavailable' }),
    garment('archived', 'shoes', { archived: true }), garment('unknown', 'shoes', { archived: undefined }),
    garment('no-owner', 'shoes', { user_id: undefined })];
  assert.deepEqual(select(garments).garments.map(g => g.id), ['yes']);
  for (const id of ['foreign', 'laundry', 'absent', 'archived', 'unknown', 'no-owner', 'missing']) {
    assert.throws(() => select(garments, { pinned_garment_id: id }), /pinned_garment_unavailable/);
  }
  assert.throws(() => select([]), /no_available/);
  assert.throws(() => select([garment('same'), garment('same')]), /duplicate_candidate/);
  assert.throws(() => selectCandidates({ garments }, undefined), /input_invalid/);
});

test('preferences and occasion rank softly while a low-ranked pin survives', () => {
  const garments = Array.from({ length: 70 }, (_, i) => garment(`top-${i}`, 'top', { colors: ['black'], formality: 1 }));
  garments.push(garment('preferred', 'top', { colors: ['blue'], seasons: ['winter'], formality: 5 }),
    garment('shoes', 'shoes'), garment('bottom', 'bottom'));
  const result = select(garments, { preferences: { colors: ['blue'], seasons: ['winter'] }, occasion: { formality: 5 }, pinned_garment_id: 'top-9' });
  assert.equal(result.garments.length, candidateLimit);
  assert.deepEqual(result.garments.slice(0, 2).map(g => g.id), ['top-9', 'preferred']);
  assert(result.garments.some(g => g.id === 'shoes'));
  assert(result.garments.some(g => g.id === 'bottom'));
  assert.deepEqual(select([...garments].reverse(), { preferences: { colors: ['blue'], seasons: ['winter'] }, occasion: { formality: 5 }, pinned_garment_id: 'top-9' }), result);
  assert.equal(select([garment('casual', 'top', { formality: 1 }), garment('formal', 'top', { formality: 5 })], { occasion: { formality: 5 } }).garments[0].id, 'formal');
  assert.equal(select([garment('a'), garment('b', 'top', { colors: ['blue'] })], { preferences: { colors: ['blue'] } }).garments[0].id, 'b');
});

test('1000 garments pass through executor and real serializer with bounded metadata and no images', async () => {
  const categories = ['bottom', 'shoes', 'dress', 'jumpsuit', 'outerwear', 'accessory', 'other'];
  const garments = Array.from({ length: 1000 }, (_, i) => garment(`item-${i}`, categories[i] ?? 'top', {
    original: 'PRIVATE_IMAGE', thumbnail: 'PRIVATE_IMAGE', storage_url: 'PRIVATE_URL', price_grosz: 1234
  }));
  let payload;
  const provider = createProvider(serverConfiguration({ AI_ENDPOINT: 'https://fixture.invalid', AI_PROVIDER: 'fixture',
    AI_RECIPIENT: 'fixture', AI_API_KEY: 'synthetic', AI_IMAGE_MODEL: 'image', AI_OUTFIT_MODEL: 'outfit' }), {
    fetchImpl: async (_url, request) => {
      payload = JSON.parse(JSON.parse(request.body).messages[1].content);
      return Response.json({ model: 'outfit', usage: { prompt_tokens: 1, completion_tokens: 1 },
        choices: [{ finish_reason: 'stop', message: { content: JSON.stringify({ outfits: [{ garment_ids: ['item-999', 'item-1'] }] }) } }] });
    }
  });
  const execute = createAIExecutor({ provider, resolveInput: async () => ({ garments, count: 3, pinned_garment_id: 'item-999', private_data: 'PRIVATE' }),
    authorize: async () => true, validateResult: async (_job, result) => result, recordTelemetry: async () => {} });
  assert.equal((await execute({ kind: 'outfit_generation', user_id: 'owner' })).outcome, 'success');
  assert.equal(payload.garments.length, candidateLimit);
  assert.equal(new Set(payload.garments.map(g => g.category)).size, 8);
  assert(payload.garments.some(g => g.id === 'item-999'));
  assert(!JSON.stringify(payload).includes('PRIVATE'));
  assert(!JSON.stringify(payload).includes('price_grosz'));
  assert(Buffer.byteLength(JSON.stringify(payload)) < 10_000);
});

test('result recheck uses full current eligibility, rejects ownership changes', async () => {
  for (const transfer of [false, true]) {
    let resolved = 0;
    const execute = createAIExecutor({
      provider: { recipient: 'fixture', analyzeImage: async () => {}, recommendOutfits: async () => ({ result: { outfits: [{ garment_ids: ['z'] }] }, telemetry: {} }) },
      resolveInput: async () => ({ count: 1, garments: resolved++ === 0 ? [garment('z')] :
        [garment('z', 'top', { user_id: transfer ? 'other' : 'owner' }), ...Array.from({ length: 50 }, (_, i) => garment(`a-${i}`))] }),
      authorize: async () => true, validateResult: async (_job, result) => result, recordTelemetry: async () => {}
    });
    assert.equal((await execute({ kind: 'outfit_generation', user_id: 'owner' })).outcome, transfer ? 'permanent' : 'success');
  }
});
