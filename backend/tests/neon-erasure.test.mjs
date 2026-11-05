import assert from 'node:assert/strict';
import { neonIdentity, privateManagementKey } from '../deletion/adapters/neon-identity.mjs';
import { localDeletionJournal } from '../deletion/adapters/local-journal.mjs';
import { mkdtemp, readFile, readdir, rm, writeFile, chmod, symlink } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { DeletionReauthentication } from '../gateway/deletion-reauth.mjs';
import { neonErasureStore } from '../deletion/adapters/neon-store.mjs';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { fileURLToPath } from 'node:url';

const owner = '11111111-1111-4111-8111-111111111111';
const options = { job: '22222222-2222-4222-8222-222222222222', fence: '33333333-3333-4333-8333-333333333333', signal: new AbortController().signal };
function fixture({ absent = false, apple = false, lease = true, deleted = false, networkError = false } = {}) {
  const calls = [];
  let missing = absent;
  const store = {
    async assertLease() { calls.push('lease'); return lease; },
    async revokeSessions() { calls.push('sessions'); },
    async hasAppleIdentity() { return apple; },
    async approveDeletion() { calls.push('approve'); },
    async identityAbsent() { return missing; }
  };
  const adapter = neonIdentity({ project: 'synthetic-project-123', branch: 'br-synthetic-123', key: 'synthetic-test-key-only', store,
    async fetchImpl(url, request) {
      calls.push('delete');
      assert.equal(url, `https://console.neon.tech/api/v2/projects/synthetic-project-123/branches/br-synthetic-123/auth/users/${owner}`);
      assert.equal(request.redirect, 'error');
      assert.equal(request.method, 'DELETE');
      missing = deleted;
      if (networkError) throw new Error('secret provider details');
      return new Response(null, { status: 404 });
    }
  });
  return { adapter, calls };
}
{
  const { adapter, calls } = fixture({ deleted: true, networkError: true });
  await adapter.deleteAccount(owner, options);
  assert.deepEqual(calls, ['lease', 'approve', 'delete', 'lease']);
}
for (const networkError of [true, false]) {
  const { adapter } = fixture({ networkError });
  await assert.rejects(adapter.deleteAccount(owner, options), /identity_deletion_unconfirmed/);
}
{
  const { adapter, calls } = fixture({ absent: true });
  await adapter.deleteAccount(owner, options);
  assert.deepEqual(calls, ['lease']);
}
{
  const { adapter, calls } = fixture({ lease: false });
  await assert.rejects(adapter.deleteAccount(owner, options), /lease_lost/);
  assert(!calls.includes('delete'));
}
{
  const { adapter } = fixture({ apple: true });
  await assert.rejects(adapter.revokeAppleTokens(owner, options), /apple_revocation_unavailable/);
  await assert.rejects(adapter.deleteAccount('../other-owner', options), /invalid_deletion_context/);
  await assert.rejects(adapter.deleteAccount(owner, { ...options, fence: undefined }), /invalid_deletion_context/);
}
assert.throws(() => neonIdentity({ project: 'synthetic-project', branch: 'br-synthetic', key: '' }), /identity_configuration_required/);
assert.throws(() => neonErasureStore({ connectionString:'not-a-url-private-sentinel',sslRootCert:'/synthetic-ca' }), error => error.message==='secure_erasure_database_configuration_required');
await assert.rejects(promisify(execFile)(process.execPath,[fileURLToPath(new URL('../deletion/worker.mjs',import.meta.url)),fileURLToPath(new URL('../deletion/neon-runtime.mjs',import.meta.url))],
  {env:{PATH:process.env.PATH,ERASURE_RUNTIME_ENABLED:'false',DATABASE_URL:'private-runtime-sentinel'},timeout:3000}),error=>{
    assert.match(error.stderr,/erasure_runtime_configuration_required/);
    assert(!error.stderr.includes('private-runtime-sentinel'));
    return true;
  });
{
  const principal={owner,sessionID:options.job,email:'owner@example.test'};
  let verified=0,loggedOut=0;
  const service=new DeletionReauthentication({store:{async deletionReauthentication(){return {email:principal.email};}},
    auth:{async verifyOTP(){verified++;return {...principal,owner:options.fence,sessionID:options.fence,token:'synthetic-managed-session.signature'};},async logout(){loggedOut++;}}});
  const input={operation_id:options.job,proof:{challenge_id:options.fence,code:'123456'}};
  await assert.rejects(service.confirm(principal,{...input,owner:options.fence}),/invalid_request/);
  assert.equal(verified,0,'caller cannot inject owner or provider session fields');
  await assert.rejects(service.confirm(principal,input),/reauthentication_required/);
  assert.equal(loggedOut,1,'a provider response for another owner is rejected and its temporary session revoked');
}
{
  const directory = await mkdtemp(join(tmpdir(), 'szafa-erasure-journal-'));
  try {
    const keyPath = join(directory, 'synthetic-key');
    await writeFile(keyPath, 'synthetic-test-key-only', { mode: 0o600 });
    assert.equal(await privateManagementKey(keyPath), 'synthetic-test-key-only');
    await chmod(keyPath, 0o644);
    await assert.rejects(privateManagementKey(keyPath), /management_key_unavailable/);
    await chmod(keyPath, 0o600);
    const linkPath = join(directory, 'linked-key');
    await symlink(keyPath, linkPath);
    await assert.rejects(privateManagementKey(linkPath));
    await rm(linkPath); await rm(keyPath);
    const journal = localDeletionJournal({ directory, assertLease: async () => true });
    await Promise.all(Array.from({ length: 8 }, () => journal.recordDeletion(owner, options.job, options)));
    const files = await readdir(directory);
    assert.deepEqual(files, [`${options.job}.json`]);
    assert.deepEqual(JSON.parse(await readFile(join(directory, files[0]), 'utf8')), { version: 1, owner, job: options.job });
    await assert.rejects(journal.recordDeletion(options.fence, options.job, options), /journal_conflict/);
    const stale = localDeletionJournal({ directory, assertLease: async () => false });
    await assert.rejects(stale.recordDeletion(owner, options.job, options), /lease_lost/);
    assert.deepEqual(await readdir(directory), files);
  } finally { await rm(directory, { recursive: true, force: true }); }
}
console.log('OK: managed erasure requires fenced context and database-confirmed deletion');
