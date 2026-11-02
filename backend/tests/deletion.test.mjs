import assert from 'node:assert/strict';
import { requestDeletion, runDeletionOnce } from '../deletion/service.mjs';

let writes = 0;
const store = { begin: async () => { writes++; return 'job'; } };
await assert.rejects(requestDeletion({ store, identity: {
  reauthenticate: async () => ({ subject: 'other', purpose: 'account_deletion', authenticatedAt: Date.now() })
} }, { subject: 'owner' }, { operationID: 'operation', proof: {} }), /reauthentication_required/);
assert.equal(writes, 0);
await assert.rejects(requestDeletion({ store }, null, {}), /reauthentication_required/);
const identity = { reauthenticate: async () => ({ subject: 'owner', purpose: 'account_deletion', authenticatedAt: Date.now() }) };
for (let i = 0; i < 2; i++) assert.deepEqual(await requestDeletion({ store, identity },
  { subject: 'owner' }, { operationID: 'operation', proof: {} }), { jobID: 'job', status: 'queued' });

// Provider failure never acknowledges cleanup. Lease recovery repeats safely.
const calls = [];
let fail = true;
const job = { id: 'job', owner: 'owner', lease: 'lease', images: ['image'] };
const deps = {
  store: { claim: async () => job, finish: async () => calls.push('finished') },
  identity: {
    revokeSessions: async () => calls.push('sessions'),
    revokeApple: async () => { calls.push('apple'); if (fail) throw new Error('provider_unavailable'); },
    deleteUser: async () => calls.push('user')
  },
  storage: { remove: async id => calls.push(id) }
};
await assert.rejects(runDeletionOnce(deps), /provider_unavailable/);
assert.deepEqual(calls, ['sessions', 'apple']);
fail = false;
await runDeletionOnce(deps);
assert.deepEqual(calls, ['sessions', 'apple', 'sessions', 'apple', 'image', 'user', 'finished']);
assert.equal(await runDeletionOnce({ store: { claim: async () => null } }), false);
console.log('PASS: deletion identity boundary, replay and interrupted revocation recovery');

const { mkdtemp, mkdir, writeFile, access, rm } = await import('node:fs/promises');
const { tmpdir } = await import('node:os');
const { join } = await import('node:path');
const { privateDeletionStorage } = await import('../deletion/storage.mjs');
const directory = await mkdtemp(join(tmpdir(), 'deletion-test-'));
try {
  const id = '00000000-0000-0000-0000-000000000017';
  await mkdir(join(directory, id));
  await writeFile(join(directory, id, 'original.jpg'), 'synthetic');
  await writeFile(join(directory, id, 'thumbnail.jpg'), 'synthetic');
  const storage = privateDeletionStorage(directory);
  await assert.rejects(storage.remove('../escape'), /invalid_upload_id/);
  await storage.remove(id);
  await storage.remove(id);
  await assert.rejects(access(join(directory, id)), { code: 'ENOENT' });
} finally { await rm(directory, { recursive: true, force: true }); }
console.log('PASS: private image namespace removal, replay and traversal rejection');
