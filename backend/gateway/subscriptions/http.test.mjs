import test from 'node:test';
import assert from 'node:assert/strict';
import { once } from 'node:events';
import { createGateway } from '../server.mjs';
import { GatewayError } from '../managed-auth.mjs';
import { SubscriptionVerificationError } from './verification.mjs';

const owner = '4169a0d2-1c38-4164-a5ca-80a4da17cd3b';
const sessionToken = 'synthetic-managed-session.signature%3D';
async function fixture(t, enabled = true) {
  const state = { active: true, verify: 0, writes: [], error: null, storageError: false, test: false };
  const event = { transaction: { owner }, eventID: 'fixture-verified' };
  const store = {
    operations: new Set(),
    async session() { if (!state.active) throw new GatewayError('unauthorized', 401); },
    async receiveSubscription(principal, value) {
      if (state.storageError) throw new Error('private database details');
      state.writes.push({ principal, value }); return { transactionID: '1001', duplicate: false };
    },
    async subscriptionStatus(principal, environment) {
      assert.equal(principal.owner, owner); assert.equal(environment, 'sandbox');
      if (state.storageError) throw new Error('private database details');
      return [];
    },
  };
  const subscriptions = enabled ? {
    catalog: () => ({ available: true, environment: 'sandbox' }),
    async transaction(value, account) {
      state.verify++; assert.equal(account, owner);
      if (state.error) throw state.error;
      if (value !== 'verified-fixture') throw new SubscriptionVerificationError();
      return event;
    },
    async notification(value) {
      state.verify++;
      if (value !== 'verified-fixture') throw new SubscriptionVerificationError();
      return state.test ? { test: true } : event;
    },
  } : null;
  const server = createGateway({ store, subscriptions, auth: {
    async current(token) { if (token !== sessionToken) throw new GatewayError('unauthorized', 401); return { owner }; },
  } });
  server.listen(0, '127.0.0.1'); await once(server, 'listening');
  t.after(() => new Promise(resolve => { server.closeAllConnections(); server.close(resolve); }));
  const url = `http://127.0.0.1:${server.address().port}/v1/subscriptions/`;
  const call = (path, body, authenticated = true, forwardedAddress) => fetch(url + path, {
    method: body === undefined ? 'GET' : 'POST', headers: { 'Content-Type': 'application/json',
      ...(authenticated ? { Authorization: `Bearer ${sessionToken}` } : {}),
      ...(forwardedAddress ? { 'X-Forwarded-For': forwardedAddress } : {}) },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }),
  });
  return { state, call };
}

test('purchase routes authenticate and recheck account before verification or persistence', async t => {
  const { state, call } = await fixture(t);
  assert.equal((await call('transactions', { signedTransaction: 'verified-fixture' }, false)).status, 401);
  state.active = false;
  assert.equal((await call('transactions', { signedTransaction: 'verified-fixture' })).status, 401);
  assert.equal(state.verify, 0); assert.equal(state.writes.length, 0);
  state.active = true;
  const result = await call('transactions', { signedTransaction: 'verified-fixture' });
  assert.equal(result.status, 200); assert.equal((await result.json()).transactionID, '1001');
  assert.equal(state.writes[0].principal.owner, owner);
  assert.equal((await call('status')).status, 200);
});

test('unconfigured subscriptions fail closed without processing a receipt', async t => {
  const { state, call } = await fixture(t, false);
  for (const path of ['catalog', 'status']) assert.equal((await call(path)).status, 503);
  assert.equal((await call('transactions', { signedTransaction: 'verified-fixture' })).status, 503);
  assert.equal((await call('apple-notifications', { signedPayload: 'verified-fixture' }, false)).status, 503);
  assert.equal(state.verify, 0); assert.equal(state.writes.length, 0);
});

test('catalog preflight cannot enable charging while subscription storage is unavailable', async t => {
  const { state, call } = await fixture(t);
  state.storageError = true;
  const result = await call('catalog');
  assert.equal(result.status, 503);
  assert.equal((await result.text()).includes('private'), false);
  assert.equal(state.verify, 0); assert.equal(state.writes.length, 0);
});

test('forged, oversized and extra-field receipts never reach persistence', async t => {
  const { state, call } = await fixture(t);
  assert.equal((await call('transactions', { signedTransaction: 'forged' })).status, 422);
  assert.equal((await call('transactions', { signedTransaction: 'verified-fixture', owner })).status, 400);
  assert.equal((await call('transactions', { signedTransaction: 'x'.repeat(36000) })).status, 413);
  state.error = new SubscriptionVerificationError('subscription_account_mismatch', 403);
  assert.equal((await call('transactions', { signedTransaction: 'verified-fixture' })).status, 403);
  assert.equal(state.writes.length, 0);
});

test('Apple webhook requires verified signatures, retries storage failures and handles TEST without a write', async t => {
  const { state, call } = await fixture(t);
  assert.equal((await call('apple-notifications', { signedPayload: 'forged' }, false)).status, 422);
  assert.equal(state.writes.length, 0);
  state.test = true;
  assert.equal((await call('apple-notifications', { signedPayload: 'verified-fixture' }, false)).status, 200);
  assert.equal(state.writes.length, 0);
  state.test = false; state.storageError = true;
  const failed = await call('apple-notifications', { signedPayload: 'verified-fixture' }, false);
  assert.equal(failed.status, 503); assert.equal((await failed.text()).includes('private'), false);
  state.storageError = false;
  assert.equal((await call('apple-notifications', { signedPayload: 'verified-fixture' }, false)).status, 200);
  assert.equal(state.writes[0].principal, null);
});

test('verification is rate bounded without trusting forwarded addresses', async t => {
  const { state, call } = await fixture(t);
  for (let i = 0; i < 60; i++) assert.equal((await call('apple-notifications', { signedPayload: 'forged' }, false, `192.0.2.${i}`)).status, 422);
  assert.equal((await call('apple-notifications', { signedPayload: 'verified-fixture' }, false, '192.0.2.100')).status, 429);
  assert.equal(state.verify, 60); assert.equal(state.writes.length, 0);
});
