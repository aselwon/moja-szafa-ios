import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, readFile, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { execFileSync } from 'node:child_process';
import { sign, X509Certificate } from 'node:crypto';
import { SignedDataVerifier, Environment } from '@apple/app-store-server-library';
import { AppleSubscriptions, createSubscriptionVerifier } from './verification.mjs';

// Ephemeral test CA, never Apple's private keys. Exercise the actual SDK chain
// and ES256 verifier without OCSP network calls; runtime always enables OCSP.
test('SDK verifies an ES256 chain and rejects tampering, wrong trust and missing Apple policy', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'szafa-receipt-chain-'));
  const openssl = (...args) => execFileSync('openssl', args, { cwd: directory, stdio: 'pipe' });
  try {
    const config = '[req]\ndistinguished_name=dn\n[dn]\n[ca]\nbasicConstraints=critical,CA:TRUE\nkeyUsage=critical,keyCertSign,cRLSign\n';
    await writeFile(join(directory, 'root.cnf'), config, { mode: 0o600 });
    const key = name => openssl('ecparam', '-name', 'prime256v1', '-genkey', '-noout', '-out', `${name}.key`);
    key('root');
    openssl('req', '-new', '-x509', '-key', 'root.key', '-out', 'root.pem', '-days', '2', '-subj', '/CN=Szafa ephemeral test root', '-config', 'root.cnf', '-extensions', 'ca');
    async function certificate(name, issuer, extensions) {
      key(name);
      openssl('req', '-new', '-key', `${name}.key`, '-out', `${name}.csr`, '-subj', `/CN=Szafa ephemeral ${name}`, '-config', 'root.cnf');
      await writeFile(join(directory, `${name}.ext`), extensions, { mode: 0o600 });
      openssl('x509', '-req', '-in', `${name}.csr`, '-CA', `${issuer}.pem`, '-CAkey', `${issuer}.key`, '-CAcreateserial', '-out', `${name}.pem`, '-days', '1', '-extfile', `${name}.ext`);
    }
    await certificate('intermediate', 'root', 'basicConstraints=critical,CA:TRUE\nkeyUsage=critical,keyCertSign,cRLSign\n1.2.840.113635.100.6.2.1=DER:05:00\n');
    await certificate('leaf', 'intermediate', 'basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\n1.2.840.113635.100.6.11.1=DER:05:00\n');
    await certificate('no-policy', 'intermediate', 'basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\n');
    const raw = async name => new X509Certificate(await readFile(join(directory, `${name}.pem`))).raw;
    const root = await raw('root'), intermediate = await raw('intermediate');
    const configuration = { environment: Environment.SANDBOX, bundleId: 'test.szafa', monthly: 'test.monthly', yearly: 'test.yearly' };
    const verifier = () => new SignedDataVerifier([root], false, Environment.SANDBOX, configuration.bundleId);
    const adapter = new AppleSubscriptions(configuration, verifier());
    const now = Date.now(), owner = '4169a0d2-1c38-4164-a5ca-80a4da17cd3b';
    const claims = { bundleId: configuration.bundleId, environment: 'Sandbox', type: 'Auto-Renewable Subscription',
      productId: configuration.monthly, transactionId: '1001', originalTransactionId: '1001', appAccountToken: owner,
      purchaseDate: now, expiresDate: now + 3600000, signedDate: now, inAppOwnershipType: 'PURCHASED' };
    const encode = value => Buffer.from(JSON.stringify(value)).toString('base64url');
    async function signed(payload, name = 'leaf') {
      const header = { alg: 'ES256', x5c: [await raw(name), intermediate, root].map(value => value.toString('base64')) };
      const body = `${encode(header)}.${encode(payload)}`;
      const signature = sign('sha256', Buffer.from(body), { key: await readFile(join(directory, `${name}.key`)), dsaEncoding: 'ieee-p1363' });
      return `${body}.${signature.toString('base64url')}`;
    }
    const valid = await signed(claims);
    const accepted = await adapter.transaction(valid, owner);
    assert.equal(accepted.transaction.transactionID, '1001');
    assert.equal(accepted.transaction.owner, owner);
    const renewal = await signed({ environment: 'Sandbox', originalTransactionId: '1001', productId: configuration.monthly,
      signedDate: now, gracePeriodExpiresDate: now + 7200000, isInBillingRetryPeriod: true, autoRenewStatus: 1 });
    const notification = { notificationType: 'DID_FAIL_TO_RENEW', notificationUUID: 'df040ecf-9816-43c7-96a0-cdb12186c510',
      signedDate: now, data: { environment: 'Sandbox', bundleId: configuration.bundleId,
        signedTransactionInfo: valid, signedRenewalInfo: renewal } };
    const acceptedNotification = await adapter.notification(await signed(notification));
    assert.equal(acceptedNotification.transaction.transactionID, '1001');
    assert.equal(acceptedNotification.renewal.graceExpiresAt, now + 7200000);
    const renewalParts = renewal.split('.');
    const tamperedRenewal = `${renewalParts[0]}.${encode({ environment: 'Sandbox', originalTransactionId: '1001', signedDate: now, gracePeriodExpiresDate: now + 999999999 })}.${renewalParts[2]}`;
    await assert.rejects(adapter.notification(await signed({ ...notification, data: { ...notification.data, signedRenewalInfo: tamperedRenewal } })), { code: 'invalid_signed_transaction' });
    const parts = valid.split('.');
    await assert.rejects(adapter.transaction(`${parts[0]}.${encode({ ...claims, expiresDate: now + 99999999 })}.${parts[2]}`, owner), { code: 'invalid_signed_transaction' });
    await assert.rejects(adapter.transaction(await signed(claims, 'no-policy'), owner), { code: 'invalid_signed_transaction' });
    await assert.rejects(adapter.transaction(await signed({ ...claims, bundleId: 'foreign.app' }), owner), { code: 'invalid_signed_transaction' });
    await assert.rejects(adapter.transaction(await signed({ ...claims, environment: 'Production' }), owner), { code: 'invalid_signed_transaction' });
    await assert.rejects(adapter.transaction(await signed({ ...claims, signedDate: now - 864000000 }), owner), { code: 'invalid_signed_transaction' });
    // The production factory pins Apple's root; our otherwise valid test chain
    // must fail there before any OCSP request can be made.
    const runtime = await createSubscriptionVerifier({ SUBSCRIPTIONS_ENVIRONMENT: 'sandbox', SUBSCRIPTIONS_BUNDLE_ID: 'test.szafa', SUBSCRIPTIONS_MONTHLY_PRODUCT_ID: 'test.monthly', SUBSCRIPTIONS_YEARLY_PRODUCT_ID: 'test.yearly' });
    await assert.rejects(runtime.transaction(valid, owner), { code: 'invalid_signed_transaction' });
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});
