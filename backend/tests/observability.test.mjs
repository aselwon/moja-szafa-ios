import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, readFile, rm, stat, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { once } from 'node:events';
import { GatewayMetrics } from '../observability/gateway-metrics.mjs';
import { createGateway } from '../gateway/server.mjs';

const close = server => new Promise(resolve => { server.closeAllConnections(); server.close(resolve); });

test('HTTP metrics record logical RPC failures and never retain request content or path identifiers', async t => {
  const metrics = new GatewayMetrics({ operations: ['api_v1_sync'] });
  const server = createGateway({ metrics, auth: { current: async () => ({ owner: 'private-owner' }) },
    store: { operations: new Set(['api_v1_sync']), session: async () => {},
      rpc: async () => ({ error: { code: 'version_conflict', message: 'private-database-detail' } }) } });
  server.listen(0, '127.0.0.1'); await once(server, 'listening'); t.after(() => close(server));
  const base = `http://127.0.0.1:${server.address().port}`;
  await fetch(base + '/rest/v1/rpc/api_v1_sync', { method: 'POST', headers: {
    Authorization: 'Bearer private-token-long-enough-for-test', 'content-type': 'application/json',
  }, body: JSON.stringify({ request: { name: 'private-wardrobe-content' } }) }).then(r => r.text());
  await fetch(base + '/v1/images/private-image-id?signature=private-signature').then(r => r.text());
  await fetch(base + '/private-email@example.test').then(r => r.text());
  const snapshot = metrics.snapshot(); const encoded = JSON.stringify(snapshot);
  for (const secret of ['private-owner', 'private-token', 'private-wardrobe-content', 'private-image-id', 'private-signature',
    'private-email@example.test', 'private-database-detail', 'Authorization']) assert.equal(encoded.includes(secret), false);
  assert.equal(snapshot.rows.find(row => row.route === 'rpc:api_v1_sync').outcome, 'rpc_error');
  assert.equal(snapshot.rows.find(row => row.route === 'images').outcome, 'client_error');
  assert.equal(snapshot.rows.find(row => row.route === 'unknown').count, 1);
  assert.equal(snapshot.rows.reduce((n, row) => n + row.count, 0), 3);
});

test('metrics persist privately, preserve exact histogram counts and prune old UTC days', async t => {
  const directory = await mkdtemp(join(tmpdir(), 'szafa-metrics-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  let now = new Date('2026-11-05T10:00:00Z');
  const metrics = new GatewayMetrics({ directory, now: () => now });
  for (const durationMs of [0, 50, 51, 800, 60_001]) metrics.record({ route: 'health', method: 'GET', status: 200, durationMs });
  await Promise.all([metrics.flush(), metrics.flush()]);
  const file = join(directory, 'gateway-metrics.json');
  assert.equal((await stat(file)).mode & 0o777, 0o600);
  const restored = new GatewayMetrics({ directory, now: () => now }); await restored.restore();
  assert.deepEqual(restored.snapshot(), metrics.snapshot());
  assert.deepEqual(restored.snapshot().rows[0].buckets, [2, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0]);
  assert.equal(restored.snapshot().rows[0].over_60s, 1);
  now = new Date('2026-11-12T00:00:00Z');
  assert.deepEqual(restored.snapshot().rows, []);
  const bad = JSON.parse(await readFile(file)); bad.rows[0].token = 'must-not-be-restored';
  await writeFile(file, JSON.stringify(bad));
  await assert.rejects(restored.restore(), /invalid_metrics_row/);
});

test('attacker-controlled routes and methods cannot expand label cardinality', () => {
  const metrics = new GatewayMetrics();
  for (let i = 0; i < 10_000; i++) metrics.record({ route: `private-${i}`, method: `private-${i}`, status: 400, durationMs: 1 });
  const rows = metrics.snapshot().rows;
  assert.equal(rows.length, 1); assert.equal(rows[0].route, 'unknown'); assert.equal(rows[0].method, 'OTHER'); assert.equal(rows[0].count, 10_000);
  metrics.record({ route: 'health', method: 'GET', status: 200, durationMs: NaN });
  assert.equal(metrics.snapshot().rows.length, 1);
});

test('AI estimates use recorded token usage, preserve unknown calls and never pretend to be an invoice', async () => {
  const { estimateAICost } = await import('../observability/ai-cost.mjs');
  const result = estimateAICost([{ provider: 'cloudflare', model: '@cf/meta/llama-3.1-8b-instruct-fp8-fast',
    calls: '2', calls_with_usage: '1', input_tokens: '1000000', output_tokens: '1000000' },
  { provider: 'unknown', model: 'unknown', calls: '1', calls_with_usage: '0', input_tokens: '0', output_tokens: '0' }]);
  assert.equal(result.estimated_neurons_for_known_usage, '38987.000000');
  assert.equal(result.estimated_list_price_usd_for_known_usage, '0.428857000000');
  assert.equal(result.unknown_cost_calls, '2'); assert.equal(result.measured_calls, '1'); assert.equal(result.invoice_cost_usd, null);
  assert.throws(() => estimateAICost([{ calls: '1', calls_with_usage: '2' }]), /invalid_ai_counts/);
});

test('operational alerts distinguish call-credit limits from actual currency spend', async () => {
  const { summarizeObservability } = await import('../observability/report.mjs');
  const report = summarizeObservability({ ai_calls: [], ai_policy: { enabled: true, daily_global_call_credit_limit: 10, dispatched_call_credits_today: 8 } }, { dropped_samples: 0 });
  assert.deepEqual(report.alerts, ['ai_call_credits_at_80_percent']);
  assert.equal(report.ai_cost.invoice_cost_usd, null);
});


test('the deployed FP8 model has its own rate and is not conflated with FP8-fast', async () => {
  const { estimateAICost } = await import('../observability/ai-cost.mjs');
  const row = { provider: 'cloudflare', model: '@cf/meta/llama-3.1-8b-instruct-fp8',
    calls: '1', calls_with_usage: '1', input_tokens: '420', output_tokens: '117' };
  const actual = estimateAICost([row]);
  assert.equal(actual.measured_calls, '1'); assert.equal(actual.unknown_cost_calls, '0');
  assert.equal(actual.estimated_neurons_for_known_usage, '8.843736');
  assert.equal(actual.estimated_list_price_usd_for_known_usage, '0.000097281096');
  assert.equal(actual.invoice_cost_usd, null);
  assert.notEqual(actual.estimated_neurons_for_known_usage,
    estimateAICost([{ ...row, model: row.model + '-fast' }]).estimated_neurons_for_known_usage);
});
