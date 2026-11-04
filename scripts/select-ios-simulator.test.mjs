import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import test from 'node:test';

const iphone = { productFamily: 'iPhone', identifier: 'iphone-compatible' };
const runtime = (version, overrides = {}) => ({
  version, identifier: `com.apple.CoreSimulator.SimRuntime.iOS-${version.replaceAll('.', '-')}`,
  isAvailable: true, supportedDeviceTypes: [iphone], ...overrides,
});
const select = runtimes => spawnSync(process.execPath, [new URL('./select-ios-simulator.mjs', import.meta.url).pathname], {
  input: JSON.stringify({ runtimes }), encoding: 'utf8',
});

test('selects newest available compatible iOS runtime numerically, not an existing shared device', () => {
  const result = select([
    runtime('26.9'), runtime('26.10'), runtime('27.0', { isAvailable: false }),
    runtime('28.0', { supportedDeviceTypes: [{ productFamily: 'iPad', identifier: 'ipad' }] }),
    runtime('29.0', { identifier: 'com.apple.CoreSimulator.SimRuntime.tvOS-29-0' }),
  ]);
  assert.equal(result.status, 0);
  assert.equal(result.stdout.trim(), 'iphone-compatible com.apple.CoreSimulator.SimRuntime.iOS-26-10');
});

test('fails clearly when no compatible available iPhone runtime exists', () => {
  for (const runtimes of [[], [runtime('26.5', { isAvailable: false })], [runtime('26.5', { supportedDeviceTypes: [] })]]) {
    const result = select(runtimes);
    assert.equal(result.status, 1);
    assert.equal(result.stdout, '');
    assert.match(result.stderr, /No available iOS runtime/);
  }
});
