import assert from 'node:assert/strict';
import { requestDeletion, runDeletionOnce } from '../deletion/service.mjs';

const request = { operationID: 'operation', challengeID: 'challenge', code: 'synthetic' };
let enqueues = 0;
const dependencies = {
  auth: { verifyDeletionProof: async () => null },
  store: { enqueue: async () => { enqueues++; return 'job'; } }
};
await assert.rejects(requestDeletion(dependencies, 'bearer', request), /reauthorization_required/);
assert.equal(enqueues, 0);
await assert.rejects(requestDeletion(dependencies, 'bearer', { ...request, owner: 'victim' }), /invalid_request/);
dependencies.auth.verifyDeletionProof = async (bearer, proof) => {
  assert.equal(bearer, 'bearer'); assert.deepEqual(proof, request); return 'verified-owner';
};
dependencies.store.enqueue = async (owner, operation) => {
  assert.equal(owner, 'verified-owner'); assert.equal(operation, request.operationID); return 'durable-job';
};
assert.deepEqual(await requestDeletion(dependencies, 'bearer', request), { jobID: 'durable-job', status: 'queued' });

const job = { id: 'job', owner: 'owner', token: 'lease' };
let finished = [];
const store = { claim: async () => job, finish: async (j, success) => { assert.equal(j, job); finished.push(success); } };
const steps = ['revokeSessions', 'revokeAppleTokens', 'removeImages', 'deleteAuthIdentity'];
for (const failedStep of steps) {
  const calls = [];
  const adapters = Object.fromEntries(steps.map(name => [name, async (owner, id) => {
    assert.equal(owner, job.owner); assert.equal(id, job.id); calls.push(name);
    if (name === failedStep) throw new Error('private details must not be logged');
  }]));
  assert.equal(await runDeletionOnce(store, adapters), true);
  assert.deepEqual(calls, steps.slice(0, steps.indexOf(failedStep) + 1));
  assert.equal(finished.at(-1), false);
}
const erased = new Set();
const adapters = Object.fromEntries(steps.map(name => [name, async () => erased.add(name)]));
await runDeletionOnce(store, adapters);
await runDeletionOnce(store, adapters); // recovery after ambiguous response
assert.equal(erased.size, 4);
assert.equal(finished.at(-1), true);
const count = finished.length;
await assert.rejects(runDeletionOnce({ ...store, finish: async () => { throw new Error('lost_commit'); } }, adapters), /lost_commit/);
assert.equal(finished.length, count);
assert.equal(await runDeletionOnce({ claim: async () => null }, {}), false);
console.log('OK: T017 reauthorization boundary, failure ordering, idempotent adapter replay and lost commit');
