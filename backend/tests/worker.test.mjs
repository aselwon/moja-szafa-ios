import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { runOnce, processExecutor } from '../worker/worker.mjs';

const job = { id: 'job', lease_token: 'lease', input: { reference: 'private' } };
function store(claim = job) {
  return { calls: [], claim: async () => claim,
    async finish(...args) { this.calls.push(args); return true; } };
}
test('idle worker does not invoke adapter or settle usage', async () => {
  const s = store(null);
  assert.equal(await runOnce(s, () => { assert.fail(); }), false);
  assert.deepEqual(s.calls, []);
});
test('passes persisted input and lease to adapter and atomic finish', async () => {
  const s = store();
  await runOnce(s, async value => { assert.equal(value, job); return { outcome: 'success', output: { category: 'top' } }; });
  assert.deepEqual(s.calls, [[job, 'success', { category: 'top' }]]);
});
test('only explicit retries are retryable; unknown errors/results are permanent', async () => {
  for (const response of [{ outcome: 'retry' }, { outcome: 'permanent' }, {}, { outcome: 'success', output: [] }]) {
    const s = store();
    await runOnce(s, async () => response);
    assert.equal(s.calls[0][1], response.outcome === 'retry' ? 'retry' : 'permanent');
  }
  const s = store();
  await runOnce(s, async () => { throw new Error('private provider error'); });
  assert.equal(s.calls[0][1], 'permanent');
});
test('ambiguous completion does not resubmit, release or settle again', async () => {
  let finishes = 0;
  await assert.rejects(runOnce({ claim: async () => job, finish: async () => { finishes++; throw new Error('lost response'); } },
    async () => ({ outcome: 'success', output: {} })));
  assert.equal(finishes, 1);
});
test('hung adapter is killed; timeout is persisted for bounded database retry', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'wardrobe-worker-'));
  try {
    const path = join(directory, 'adapter.sh');
    await writeFile(path, '#!/bin/sh\nexec sleep 5\n', { mode: 0o700 });
    const s = store();
    await runOnce(s, processExecutor(path, 200));
    assert.equal(s.calls[0][1], 'timeout');
    await writeFile(path, `#!/bin/sh
read -r input
printf '{"outcome":"success","output":%s}\\n' "$input"
`);
    const response = await processExecutor(path)(job);
    assert.deepEqual(response, { outcome: 'success', output: job });
  } finally { await rm(directory, { recursive: true, force: true }); }
});
