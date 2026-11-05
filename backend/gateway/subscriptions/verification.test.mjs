import test from 'node:test';
import assert from 'node:assert/strict';
import { subscriptionConfiguration, createSubscriptionVerifier, AppleSubscriptions, SubscriptionVerificationError } from './verification.mjs';

const owner = '00000000-0000-4000-8000-000000000001';
const now = 1_793_840_000_000;
const env = { SUBSCRIPTIONS_ENVIRONMENT: 'sandbox', SUBSCRIPTIONS_BUNDLE_ID: 'pl.mojaszafa.app.staging',
  SUBSCRIPTIONS_MONTHLY_PRODUCT_ID: 'test.monthly', SUBSCRIPTIONS_YEARLY_PRODUCT_ID: 'test.yearly' };
const jws = `${Buffer.from(JSON.stringify({ alg: 'ES256', x5c: ['AA==','AA==','AA=='] })).toString('base64url')}.e30.c2lnbmF0dXJl`;
function claims(overrides = {}) {
  return { bundleId: env.SUBSCRIPTIONS_BUNDLE_ID, environment: 'Sandbox', type: 'Auto-Renewable Subscription',
    transactionId: '123', originalTransactionId: '120', productId: 'test.monthly', appAccountToken: owner,
    purchaseDate: now - 1000, expiresDate: now + 86400000, signedDate: now, inAppOwnershipType: 'PURCHASED', ...overrides };
}
// Only the normalization tests inject a verifier. Runtime always constructs
// Apple's real verifier from the pinned public CA with online checks enabled.
function normalizer(transaction = claims(), notification, renewal) {
  return new AppleSubscriptions(subscriptionConfiguration(env), {
    async verifyAndDecodeTransaction() { return transaction; },
    async verifyAndDecodeNotification() { return notification; },
    async verifyAndDecodeRenewalInfo() { return renewal; },
  }, () => now);
}

test('subscription configuration is unavailable by default and rejects test bypass environments', async () => {
  assert.equal(subscriptionConfiguration({}), null); assert.equal(await createSubscriptionVerifier({}), null);
  for (const environment of ['Xcode', 'xcode', 'LocalTesting', 'local_testing', 'staging']) {
    assert.throws(() => subscriptionConfiguration({ ...env, SUBSCRIPTIONS_ENVIRONMENT: environment }), /configuration_invalid/);
  }
  assert.throws(() => subscriptionConfiguration({ ...env, SUBSCRIPTIONS_ENVIRONMENT: 'production' }), /configuration_invalid/);
  assert.throws(() => subscriptionConfiguration({ ...env, SUBSCRIPTIONS_YEARLY_PRODUCT_ID: 'test.monthly' }), /configuration_invalid/);
  assert.equal(subscriptionConfiguration({ ...env, SUBSCRIPTIONS_ENVIRONMENT: 'production', SUBSCRIPTIONS_APP_APPLE_ID: '1234' }).appAppleId, 1234);
});

test('runtime Apple verifier rejects fabricated certificates and never trusts decoded claims alone', async () => {
  const verifier = await createSubscriptionVerifier(env);
  await assert.rejects(verifier.transaction(jws, owner), error => error instanceof SubscriptionVerificationError && error.status === 422);
  const unsigned = `${Buffer.from(JSON.stringify({ alg: 'none' })).toString('base64url')}.e30.c2ln`;
  await assert.rejects(verifier.transaction(unsigned, owner), /invalid_signed_transaction/);
});

test('verified transaction normalization binds account/product/environment and drops unrelated data', async () => {
  const normalized = await normalizer(claims({ email: 'private@example.test', extra: 'private contents' })).transaction(jws, owner);
  assert.equal(normalized.transaction.owner, owner); assert.equal(normalized.transaction.environment, 'sandbox');
  assert.equal(normalized.transaction.revokedAt, null); assert.match(normalized.digest, /^[a-f0-9]{64}$/);
  const encoded = JSON.stringify(normalized); assert.equal(encoded.includes('private'), false); assert.equal(encoded.includes(jws), false);
  assert.deepEqual(normalized, await normalizer().transaction(jws, owner));
  await assert.rejects(normalizer().transaction(jws, '00000000-0000-4000-8000-000000000002'), error => error.status === 403);
});

test('foreign and malformed verified claims cannot create an entitlement', async () => {
  for (const override of [
    { environment: 'Production' }, { bundleId: 'another.app' }, { productId: 'unknown.product' },
    { type: 'Consumable' }, { appAccountToken: null }, { transactionId: 123 },
    { transactionId: '0' }, { purchaseDate: now + 600000 }, { signedDate: now + 600000 },
    { expiresDate: now - 1000 }, { revokedDate: undefined, revocationDate: 'not-a-date' },
    { isUpgraded: 'true' }, { inAppOwnershipType: 'FAMILY_SHARED' },
  ]) await assert.rejects(normalizer(claims(override)).transaction(jws, owner), /invalid_signed_transaction/);
});

function notification() {
  return { notificationUUID: '00000000-0000-4000-8000-000000000009', signedDate: now, notificationType: 'DID_FAIL_TO_RENEW',
    data: { environment: 'Sandbox', bundleId: env.SUBSCRIPTIONS_BUNDLE_ID, signedTransactionInfo: jws, signedRenewalInfo: jws } };
}
function renewal(overrides = {}) {
  return { environment: 'Sandbox', originalTransactionId: '120', productId: 'test.monthly', signedDate: now,
    gracePeriodExpiresDate: now + 3600000, isInBillingRetryPeriod: true, autoRenewStatus: 1, ...overrides };
}

test('notification verifies nested transaction and renewal chain before forwarding grace data', async () => {
  const result = await normalizer(claims(), notification(), renewal()).notification(jws);
  assert.equal(result.source, 'notification'); assert.equal(result.eventID, notification().notificationUUID);
  assert.equal(result.renewal.graceExpiresAt, now + 3600000); assert.equal(result.renewal.billingRetry, true);
  for (const override of [{ environment: 'Production' }, { originalTransactionId: 'another' }, { productId: 'unknown' },
    { signedDate: now + 600000 }, { gracePeriodExpiresDate: 'tomorrow' }, { autoRenewStatus: 5 }]) {
    await assert.rejects(normalizer(claims(), notification(), renewal(override)).notification(jws), /invalid_signed_transaction/);
  }
});

test('verification outage is retryable without leaking provider error strings', async () => {
  const service = new AppleSubscriptions(subscriptionConfiguration(env), {
    async verifyAndDecodeTransaction() { throw Object.assign(new Error('secret signed payload'), { status: 2 }); },
  });
  await assert.rejects(service.transaction(jws, owner), error => error.status === 503 && error.message === 'verification_unavailable');
});
