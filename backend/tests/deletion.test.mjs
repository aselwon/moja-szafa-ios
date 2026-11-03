import assert from 'node:assert/strict';
import { AccountDeletion } from '../deletion/service.mjs';
import { deletionHandler } from '../deletion/http.mjs';
import { Readable } from 'node:stream';
const owner = '11111111-1111-4111-8111-111111111111';
const id = '22222222-2222-4222-8222-222222222222';

function fixture(failure) {
  const calls = [];
  const step = name => async () => { calls.push(name); if (failure === name) throw new Error('private provider detail'); };
  const service = new AccountDeletion({
    store: { async call(action, args) {
      calls.push(action);
      if (action === 'claim') return { id, owner, fence: id };
      if (action === 'request') return { id, status: 'accepted' };
      assert.equal(args.fence, id);
      return true;
    } },
    identity: { startDeletionChallenge: step('challenge'), verifyDeletionChallenge: async (subject, operation) => {
      calls.push('verify'); assert.equal(subject, owner); assert.equal(operation, id); return failure !== 'verify';
    }, revokeAllSessions: step('sessions'), revokeAppleTokens: step('apple'), deleteAccount: step('auth') },
    storage: { eraseAccount: step('storage') }, backups: { recordDeletion: step('backup') }
  });
  return { service, calls };
}
{
  const { service, calls } = fixture('verify');
  await assert.rejects(service.request(owner, id, {}), /reauthentication_required/);
  assert.deepEqual(calls, ['verify']);
  await assert.rejects(service.request('../another-user', id, {}), /invalid_request/);
}
{
  const { service, calls } = fixture();
  await service.request(owner, id, {});
  assert.deepEqual(calls, ['verify', 'request']);
  calls.length = 0;
  await service.tick();
  assert.deepEqual(calls, ['claim', 'backup', 'sessions', 'apple', 'storage', 'auth', 'finish']);
}
for (const failure of ['backup', 'sessions', 'apple', 'storage', 'auth']) {
  const { service, calls } = fixture(failure);
  await service.tick();
  assert.equal(calls.at(-1), 'retry');
  assert(!calls.includes('finish'), `must not report success after ${failure} failure`);
}
{
  const { service } = fixture('verify');
  const request = Readable.from([JSON.stringify({ operation_id: id, proof: {} })]);
  Object.assign(request, { method: 'POST', url: '/v1/account/deletion', headers: { authorization: 'Bearer test' } });
  let status, result;
  await deletionHandler(service, async () => owner)(request, {
    writeHead(value, headers) { status = value; assert.equal(headers['Cache-Control'], 'no-store'); },
    end(value) { result = JSON.parse(value); }
  });
  assert.equal(status, 403);
  assert.equal(result.code, 'reauthentication_required');
  assert(result.request_id);
  assert(!JSON.stringify(result).includes('private'));
}
console.log('OK: T017 reauthentication gate, cleanup ordering, fail-closed retries and HTTP errors');

{
  const { service, calls } = fixture();
  service.timeoutMs = 5;
  service.identity.revokeAppleTokens = () => new Promise(() => {});
  await service.tick();
  assert.equal(calls.at(-1), 'retry');
  assert(!calls.includes('finish'));
  assert(!calls.includes('storage'));
}
