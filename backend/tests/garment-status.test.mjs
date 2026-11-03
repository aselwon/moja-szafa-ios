import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createAIExecutor } from '../ai/executor.mjs';

test('outfit execution excludes unavailable, archived, deleted and foreign items and rechecks after generation', async () => {
  for (const changed of [false, true]) {
    let reads = 0, sent;
    const rows = [
      { id: 'ok', user_id: 'owner', availability: 'available', archived: false, deleted: false },
      ...['laundry', 'unavailable'].map(availability => ({ id: availability, user_id: 'owner', availability, archived: false, deleted: false })),
      { id: 'archived', user_id: 'owner', availability: 'available', archived: true, deleted: false },
      { id: 'deleted', user_id: 'owner', availability: 'available', archived: false, deleted: true },
      { id: 'foreign', user_id: 'other', availability: 'available', archived: false, deleted: false }
    ];
    const execute = createAIExecutor({
      provider: { recipient: 'test', analyzeImage: async () => {}, recommendOutfits: async input => {
        sent = input.garments;
        return { result: { outfits: [{ garment_ids: ['ok'] }] }, telemetry: { status: 'success' } };
      } },
      resolveInput: async () => ({ garments: rows, count: 1 }),
      currentGarments: async () => ++reads === 2 && changed ? rows.map(g => ({ ...g, archived: true })) : rows,
      authorize: async () => true, validateResult: async (_, result) => result, recordTelemetry: async () => {}
    });
    const result = await execute({ kind: 'outfit_generation', user_id: 'owner' });
    assert.deepEqual(sent.map(g => g.id), ['ok']);
    assert.equal(result.outcome, changed ? 'permanent' : 'success');
    assert.equal(reads, 2);
  }
});

test('outfit execution without current server state fails before provider dispatch', async () => {
  let calls = 0;
  const execute = createAIExecutor({
    provider: { recipient: 'test', analyzeImage: async () => {}, recommendOutfits: async () => { calls++; } },
    resolveInput: async () => ({ garments: [{ id: 'a' }], count: 1 }),
    authorize: async () => true, validateResult: async (_, result) => result, recordTelemetry: async () => {}
  });
  assert.deepEqual(await execute({ kind: 'outfit_generation', user_id: 'owner' }), { outcome: 'permanent' });
  assert.equal(calls, 0);
});
