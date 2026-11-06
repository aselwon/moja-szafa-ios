import test from 'node:test';
import assert from 'node:assert/strict';
import { generateKeyPair, SignJWT, exportJWK, createLocalJWKSet } from 'jose';
import { OperatorAuth, operatorConfiguration } from './auth.mjs';

const env = { OPS_ISSUER: 'https://identity.example', OPS_AUDIENCE: 'szafa-operations',
  OPS_JWKS_URL: 'https://identity.example/keys', OPS_PUBLIC_ORIGIN: 'https://operations.example' };

test('operator configuration defaults off and requires explicit HTTPS trust boundaries', () => {
  assert.equal(operatorConfiguration({}), null);
  const credentialsURL = new URL(env.OPS_ISSUER);
  credentialsURL.username = 'synthetic'; credentialsURL.password = 'synthetic';
  for (const patch of [{ OPS_ISSUER: undefined }, { OPS_JWKS_URL: 'https://attacker.example/keys' },
    { OPS_PUBLIC_ORIGIN: 'http://operations.example' }, { OPS_PUBLIC_ORIGIN: 'https://operations.example/path' },
    { OPS_ISSUER: credentialsURL.href }]) {
    assert.throws(() => operatorConfiguration({ ...env, ...patch }));
  }
});

test('real signed tokens require the exact issuer/audience and recent attested MFA', async () => {
  const { privateKey, publicKey } = await generateKeyPair('ES256');
  const other = await generateKeyPair('ES256');
  const now = 1793880000;
  const key = { ...await exportJWK(publicKey), kid: 'operator-test', alg: 'ES256', use: 'sig' };
  const auth = new OperatorAuth(operatorConfiguration(env), { keys: createLocalJWKSet({ keys: [key] }), now: () => now * 1000 });
  const sign = (patch = {}, header = {}, signingKey = privateKey) => new SignJWT({ iss: env.OPS_ISSUER,
    aud: env.OPS_AUDIENCE, sub: 'operator-1', jti: 'request-1', iat: now, exp: now + 300,
    auth_time: now - 30, amr: ['pwd', 'otp', 'mfa'], ...patch })
    .setProtectedHeader({ alg: 'ES256', kid: 'operator-test', typ: 'at+jwt', ...header }).sign(signingKey);
  assert.deepEqual(await auth.authenticate(await sign({ role: 'admin' })), { issuer: env.OPS_ISSUER, subject: 'operator-1' });
  for (const claims of [{ amr: ['pwd'] }, { amr: 'mfa' }, { auth_time: now - 901 }, { auth_time: now + 60 },
    { iss: 'https://evil.example' }, { aud: 'consumer-app' }, { exp: now - 10 }, { exp: now + 3600 },
    { iat: now + 60 }, { sub: '' }, { sub: 5 }, { auth_time: undefined }, { jti: undefined }]) {
    await assert.rejects(auth.authenticate(await sign(claims)), { code: 'operator_authentication_required' });
  }
  await assert.rejects(auth.authenticate(await sign({}, { typ: 'JWT' })), { code: 'operator_authentication_required' });
  await assert.rejects(auth.authenticate(await sign({}, {}, other.privateKey)), { code: 'operator_authentication_required' });
  const forged = (await sign()).split('.');
  forged[1] = Buffer.from(JSON.stringify({ sub: 'admin', amr: ['mfa'] })).toString('base64url');
  await assert.rejects(auth.authenticate(forged.join('.')), { code: 'operator_authentication_required' });
  await assert.rejects(auth.authenticate('x'.repeat(16385)), { code: 'operator_authentication_required' });
});

test('dedicated OIDC proxy profile accepts recent MFA identity tokens without access-token fallback', async () => {
  const { privateKey, publicKey } = await generateKeyPair('RS256');
  const now = 1793880000;
  const configuration = operatorConfiguration({ ...env, OPS_TOKEN_TYPE: 'oidc_id_token' });
  const key = { ...await exportJWK(publicKey), kid: 'oidc-test', alg: 'RS256', use: 'sig' };
  const options = { keys: createLocalJWKSet({ keys: [key] }), now: () => now * 1000 };
  const auth = new OperatorAuth(configuration, options);
  const accessAuth = new OperatorAuth(operatorConfiguration(env), options);
  const sign = (patch = {}, typ = 'JWT') => new SignJWT({ iss: env.OPS_ISSUER,
    aud: env.OPS_AUDIENCE, sub: 'operator-1', iat: now, exp: now + 600,
    nonce: 'proxy-validated-random-nonce', auth_time: now - 30, amr: ['pwd', 'otp', 'mfa'], ...patch })
    .setProtectedHeader({ alg: 'RS256', kid: 'oidc-test', typ }).sign(privateKey);
  assert.deepEqual(await auth.authenticate(await sign()), { issuer: env.OPS_ISSUER, subject: 'operator-1' });
  for (const patch of [{ amr: ['pwd'] }, { auth_time: now - 901 }, { auth_time: undefined },
    { nonce: undefined }, { nonce: '' }, { aud: 'consumer-app' }, { iss: 'https://evil.example' },
    { azp: 'consumer-app' }, { aud: [env.OPS_AUDIENCE, 'consumer-app'] }, { exp: now + 3600 }]) {
    await assert.rejects(auth.authenticate(await sign(patch)), { code: 'operator_authentication_required' });
  }
  await assert.rejects(auth.authenticate(await sign({ jti: 'access-1' }, 'at+jwt')), { code: 'operator_authentication_required' });
  await assert.rejects(accessAuth.authenticate(await sign({ jti: 'access-1' })), { code: 'operator_authentication_required' });
  assert.throws(() => operatorConfiguration({ ...env, OPS_TOKEN_TYPE: 'automatic' }));
});
