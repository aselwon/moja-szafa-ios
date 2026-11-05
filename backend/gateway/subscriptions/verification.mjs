import { createHash } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import { SignedDataVerifier, Environment, VerificationStatus } from '@apple/app-store-server-library';

const UUID = /^[a-f0-9]{8}(-[a-f0-9]{4}){3}-[a-f0-9]{12}$/i;
const ID = /^[1-9][0-9]{0,31}$/;
const identifier = value => typeof value === 'string' && ID.test(value);
const PRODUCT = /^[A-Za-z0-9][A-Za-z0-9._-]{2,199}$/;
const ROOT_SHA256 = '63343abfb89a6a03ebb57e9b3f5fa7be7c4f5c756f3017b3a8c488c3653e9179';
export class SubscriptionVerificationError extends Error {
  constructor(code = 'invalid_signed_transaction', status = 422) { super(code); this.code = code; this.status = status; }
}
const fail = () => { throw new SubscriptionVerificationError(); };
const timestamp = value => Number.isSafeInteger(value) && value >= 0 && value <= 4_102_444_800_000;
const hash = value => createHash('sha256').update(value).digest('hex');
function receiptID(value) {
  const bytes = Buffer.from(hash(value).slice(0, 32), 'hex'); bytes[6] = bytes[6] & 15 | 128; bytes[8] = bytes[8] & 63 | 128;
  const s = bytes.toString('hex'); return `${s.slice(0,8)}-${s.slice(8,12)}-${s.slice(12,16)}-${s.slice(16,20)}-${s.slice(20)}`;
}
function checkJWS(value) {
  if (typeof value !== 'string' || value.length > 32000 || !/^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/.test(value)) fail();
  let header;
  try { header = JSON.parse(Buffer.from(value.split('.')[0], 'base64url').toString('utf8')); } catch { fail(); }
  if (!header || header.alg !== 'ES256' || header.crit !== undefined || !Array.isArray(header.x5c) || header.x5c.length !== 3 ||
      header.x5c.some(cert => typeof cert !== 'string' || cert.length > 8000 || !/^[A-Za-z0-9+/]+={0,2}$/.test(cert))) fail();
}

export function subscriptionConfiguration(env) {
  const keys = ['SUBSCRIPTIONS_ENVIRONMENT', 'SUBSCRIPTIONS_BUNDLE_ID', 'SUBSCRIPTIONS_MONTHLY_PRODUCT_ID', 'SUBSCRIPTIONS_YEARLY_PRODUCT_ID', 'SUBSCRIPTIONS_APP_APPLE_ID'];
  if (keys.every(key => !env[key])) return null;
  const environment = ({ sandbox: Environment.SANDBOX, production: Environment.PRODUCTION })[env.SUBSCRIPTIONS_ENVIRONMENT];
  const bundleId = env.SUBSCRIPTIONS_BUNDLE_ID;
  const monthly = env.SUBSCRIPTIONS_MONTHLY_PRODUCT_ID, yearly = env.SUBSCRIPTIONS_YEARLY_PRODUCT_ID;
  const appAppleId = env.SUBSCRIPTIONS_APP_APPLE_ID ? Number(env.SUBSCRIPTIONS_APP_APPLE_ID) : undefined;
  if (!environment || typeof bundleId !== 'string' || !/^[A-Za-z0-9][A-Za-z0-9.-]{2,199}$/.test(bundleId) ||
      typeof monthly !== 'string' || typeof yearly !== 'string' || !PRODUCT.test(monthly) || !PRODUCT.test(yearly) || monthly === yearly ||
      (appAppleId !== undefined && (!Number.isSafeInteger(appAppleId) || appAppleId <= 0)) ||
      (environment === Environment.PRODUCTION && appAppleId === undefined)) throw new Error('subscription_configuration_invalid');
  return Object.freeze({ environment, bundleId, appAppleId, monthly, yearly });
}

export async function createSubscriptionVerifier(env) {
  const configuration = subscriptionConfiguration(env);
  if (!configuration) return null;
  const root = await readFile(new URL('./certificates/AppleRootCA-G3.cer', import.meta.url));
  if (hash(root) !== ROOT_SHA256) throw new Error('apple_trust_anchor_changed');
  // Online revocation and current certificate validity checks are mandatory in
  // runtime configuration. Xcode/LocalTesting bypass modes are never accepted.
  const verifier = new SignedDataVerifier([root], true, configuration.environment, configuration.bundleId, configuration.appAppleId);
  return new AppleSubscriptions(configuration, verifier);
}

export class AppleSubscriptions {
  constructor(configuration, verifier, now = () => Date.now()) {
    if (![Environment.SANDBOX, Environment.PRODUCTION].includes(configuration.environment)) throw new Error('subscription_environment_invalid');
    this.configuration = configuration; this.verifier = verifier; this.now = now;
    this.products = new Set([configuration.monthly, configuration.yearly]);
  }
  catalog() {
    return { available: true, bundleID: this.configuration.bundleId, environment: this.configuration.environment.toLowerCase(),
      monthlyProductID: this.configuration.monthly, yearlyProductID: this.configuration.yearly };
  }
  async verify(method, value) {
    checkJWS(value);
    try { return await this.verifier[method](value); }
    catch (error) {
      // Never expose signed payloads, certificate details or provider error text.
      if (error?.status === VerificationStatus.RETRYABLE_VERIFICATION_FAILURE) throw new SubscriptionVerificationError('verification_unavailable', 503);
      throw new SubscriptionVerificationError();
    }
  }
  transactionClaims(transaction) {
    if (transaction.bundleId !== this.configuration.bundleId || transaction.environment !== this.configuration.environment ||
        transaction.type !== 'Auto-Renewable Subscription' || !this.products.has(transaction.productId) ||
        !identifier(transaction.transactionId) || !identifier(transaction.originalTransactionId) ||
        typeof transaction.appAccountToken !== 'string' || !UUID.test(transaction.appAccountToken) ||
        !timestamp(transaction.purchaseDate) || !timestamp(transaction.expiresDate) || !timestamp(transaction.signedDate) ||
        transaction.purchaseDate > this.now() + 300000 || transaction.signedDate > this.now() + 300000 ||
        transaction.expiresDate <= transaction.purchaseDate ||
        (transaction.revocationDate !== undefined && !timestamp(transaction.revocationDate)) ||
        (transaction.isUpgraded !== undefined && typeof transaction.isUpgraded !== 'boolean') ||
        (transaction.inAppOwnershipType !== undefined && transaction.inAppOwnershipType !== 'PURCHASED')) fail();
    return { environment: transaction.environment.toLowerCase(), owner: transaction.appAccountToken.toLowerCase(),
      transactionID: transaction.transactionId, originalTransactionID: transaction.originalTransactionId, productID: transaction.productId,
      purchasedAt: transaction.purchaseDate, expiresAt: transaction.expiresDate, signedAt: transaction.signedDate,
      revokedAt: transaction.revocationDate ?? null, upgraded: transaction.isUpgraded ?? false };
  }
  async transaction(jws, owner) {
    const decoded = await this.verify('verifyAndDecodeTransaction', jws);
    const transaction = this.transactionClaims(decoded);
    if (typeof owner !== 'string' || transaction.owner !== owner.toLowerCase()) throw new SubscriptionVerificationError('subscription_account_mismatch', 403);
    return { source: 'transaction', eventID: receiptID(jws), digest: hash(jws), eventType: 'TRANSACTION',
      eventSignedAt: transaction.signedAt, transaction, renewal: null };
  }
  async notification(jws) {
    const notification = await this.verify('verifyAndDecodeNotification', jws);
    if (typeof notification.notificationUUID !== 'string' || !UUID.test(notification.notificationUUID) ||
        !timestamp(notification.signedDate) || notification.signedDate > this.now() + 300000) fail();
    if (notification.notificationType === 'TEST') return { test: true };
    const data = notification.data;
    if (!data || data.environment !== this.configuration.environment || data.bundleId !== this.configuration.bundleId ||
        typeof notification.notificationType !== 'string' || !/^[A-Z_]{1,60}$/.test(notification.notificationType)) fail();
    const transaction = this.transactionClaims(await this.verify('verifyAndDecodeTransaction', data.signedTransactionInfo));
    let renewal = null;
    if (data.signedRenewalInfo !== undefined) {
      const value = await this.verify('verifyAndDecodeRenewalInfo', data.signedRenewalInfo);
      if (value.environment !== this.configuration.environment || value.originalTransactionId !== transaction.originalTransactionID ||
          !this.products.has(value.productId) || !timestamp(value.signedDate) || value.signedDate > this.now() + 300000 ||
          (value.gracePeriodExpiresDate !== undefined && !timestamp(value.gracePeriodExpiresDate)) ||
          (value.isInBillingRetryPeriod !== undefined && typeof value.isInBillingRetryPeriod !== 'boolean') ||
          (value.autoRenewStatus !== undefined && ![0, 1].includes(value.autoRenewStatus))) fail();
      renewal = { signedAt: value.signedDate, graceExpiresAt: value.gracePeriodExpiresDate ?? null,
        billingRetry: value.isInBillingRetryPeriod ?? false, autoRenew: value.autoRenewStatus === 1 };
    }
    return { source: 'notification', eventID: notification.notificationUUID.toLowerCase(), digest: hash(jws),
      eventType: notification.notificationType, eventSignedAt: notification.signedDate, transaction, renewal };
  }
}
