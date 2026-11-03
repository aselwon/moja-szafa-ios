import assert from 'node:assert/strict';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { requestDeletion } from '../deletion/gateway.mjs';
import { runDeletionOnce, deletionExecutor } from '../deletion/worker.mjs';
import { privateFiles } from '../images/pipeline.mjs';

const owner = '00000000-0000-0000-0000-000000000001';
const operationID = '00000000-0000-0000-0000-000000000002';
const job = { id: operationID, owner, stage: 'sessions', lease_token: 'lease' };
const receipt = { jobID: operationID, status: 'queued' };
const calls = [];
let existing = null;
let age = 0;
let active = true;
let escrowFails = false;
const auth = {
  verifySignature: async token => {
    assert.equal(token, 'synthetic');
    return { userID: owner, authTime: 1000 - age };
  },
  requireActiveSession: async () => { calls.push('active'); if (!active) throw new Error('revoked'); },
  prepareAppleRevocation: async () => { calls.push('escrow'); if (escrowFails) throw new Error('apple_unavailable'); }
};
const store = { command: async request => {
  calls.push(request.action);
  assert.equal(request.owner, owner);
  assert.equal(request.operationID, operationID);
  if (request.action === 'receipt') return existing;
  existing = receipt;
  return receipt;
} };
const request = { bearer: 'synthetic', body: { operationID } };
const deps = { auth, store, now: () => 1000000 };
for (const invalidAge of [301, -1, NaN]) {
  age = invalidAge;
  await assert.rejects(requestDeletion(request, deps), /reauthentication_required/);
}
assert(!calls.includes('begin'));
age = 0;
escrowFails = true;
await assert.rejects(requestDeletion(request, deps), /apple_unavailable/);
assert(!calls.includes('begin'));
escrowFails = false;
assert.deepEqual(await requestDeletion(request, deps), receipt);
assert.deepEqual(calls.slice(-4), ['receipt', 'active', 'escrow', 'begin']);
// A lost acceptance response is recoverable after session revocation; no new effects.
active = false;
calls.length = 0;
assert.deepEqual(await requestDeletion(request, deps), receipt);
assert.deepEqual(calls, ['receipt']);
await assert.rejects(requestDeletion({ ...request, body: { operationID, owner } }, deps), /validation_failed/);
await assert.rejects(requestDeletion(request, { ...deps, auth: { verifySignature: async () => { throw new Error('unauthorized'); } } }), /unauthorized/);

for (const execute of [async () => { throw new Error('private provider detail'); }, async () => ({}), async () => ({ outcome: 'retry' })]) {
  const commands = [];
  const queue = { command: async request => { commands.push(request); return request.action === 'claim' ? job : true; } };
  await runDeletionOnce(queue, execute);
  assert.deepEqual(commands.map(c => c.action), ['claim', 'retry']);
  assert.equal(commands[1].token, job.lease_token);
  assert(!JSON.stringify(commands).includes('private provider'));
}
let effects = 0;
const commands = [];
const lostCommit = { command: async request => {
  commands.push(request.action);
  if (request.action === 'claim') return job;
  throw new Error('lost_commit_response');
} };
await assert.rejects(runDeletionOnce(lostCommit, async () => { effects++; return { outcome: 'success' }; }), /lost_commit_response/);
assert.equal(effects, 1);
assert.deepEqual(commands, ['claim', 'advance']);
await runDeletionOnce({ command: async request => request.action === 'claim' ? { ...job, stage: 'purge' } : true }, async () => assert.fail('purge must run in database'));
assert.equal(await runDeletionOnce({ command: async () => null }, async () => assert.fail()), false);

const directory = await mkdtemp(join(tmpdir(), 'deletion-test-'));
try {
  const storage = privateFiles(directory);
  for (const variant of ['original', 'thumbnail']) await storage.put(`${operationID}/${variant}.jpg`, Buffer.from('synthetic'));
  const execute = deletionExecutor({ command: async request => {
    assert.equal(request.token, 'lease');
    return [operationID];
  } }, storage, async () => assert.fail('images must not invoke auth provider'));
  for (let retry = 0; retry < 2; retry++) assert.equal((await execute({ ...job, stage: 'images' })).outcome, 'success');
  await assert.rejects(readFile(join(directory, operationID, 'original.jpg')), { code: 'ENOENT' });
  await assert.rejects(readFile(join(directory, operationID, 'thumbnail.jpg')), { code: 'ENOENT' });
  const fenced = deletionExecutor({ command: async () => false }, storage, async () => assert.fail());
  await assert.rejects(fenced({ ...job, stage: 'images' }), /lease_lost/);
} finally { await rm(directory, { recursive: true, force: true }); }
console.log('PASS: T017 fresh identity, Apple escrow, receipt replay, worker failure/recovery and real file cleanup');
