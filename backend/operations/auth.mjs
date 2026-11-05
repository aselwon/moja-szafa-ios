import { createRemoteJWKSet, jwtVerify } from 'jose';

export class OperatorError extends Error {
  constructor(code, status = 401) { super(code); this.code = code; this.status = status; }
}

export function operatorConfiguration(env) {
  const names = ['OPS_ISSUER', 'OPS_AUDIENCE', 'OPS_JWKS_URL', 'OPS_PUBLIC_ORIGIN'];
  if (names.every(name => !env[name])) return null;
  if (names.some(name => typeof env[name] !== 'string' || !env[name])) throw new Error('operator_configuration_invalid');
  const issuer = new URL(env.OPS_ISSUER), jwks = new URL(env.OPS_JWKS_URL), origin = new URL(env.OPS_PUBLIC_ORIGIN);
  for (const url of [issuer, jwks, origin]) {
    if (url.protocol !== 'https:' || url.username || url.password || url.hash || url.search) throw new Error('operator_configuration_invalid');
  }
  // A token can never select its issuer, audience, key endpoint or login route.
  if (jwks.origin !== issuer.origin || origin.href !== `${origin.origin}/` || env.OPS_AUDIENCE.length > 256 ||
      !env.OPS_AUDIENCE.trim() || env.OPS_ISSUER.length > 512) {
    throw new Error('operator_configuration_invalid');
  }
  return Object.freeze({ issuer: env.OPS_ISSUER, audience: env.OPS_AUDIENCE, jwksURL: jwks, origin: origin.origin });
}

export class OperatorAuth {
  constructor(configuration, { keys, now = () => Date.now() } = {}) {
    this.configuration = configuration;
    this.keys = keys ?? createRemoteJWKSet(configuration.jwksURL, { timeoutDuration: 5000, cooldownDuration: 30000, cacheMaxAge: 300000 });
    this.now = now;
  }

  async authenticate(token) {
    if (typeof token !== 'string' || token.length > 16384 || !/^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/.test(token)) {
      throw new OperatorError('operator_authentication_required');
    }
    try {
      const now = Math.floor(this.now() / 1000);
      const { payload } = await jwtVerify(token, this.keys, {
        algorithms: ['RS256', 'ES256'], typ: 'at+jwt',
        issuer: this.configuration.issuer, audience: this.configuration.audience,
        requiredClaims: ['exp', 'iat', 'sub', 'jti', 'amr', 'auth_time'],
        maxTokenAge: '15 minutes', clockTolerance: 5, currentDate: new Date(this.now()),
      });
      if (typeof payload.sub !== 'string' || payload.sub.length < 1 || payload.sub.length > 256 ||
          typeof payload.jti !== 'string' || payload.jti.length < 1 || payload.jti.length > 256 ||
          !Number.isSafeInteger(payload.auth_time) || payload.auth_time > now + 5 || now - payload.auth_time > 900 ||
          !Number.isSafeInteger(payload.iat) || !Number.isSafeInteger(payload.exp) || payload.exp <= payload.iat || payload.exp - payload.iat > 900 ||
          !Array.isArray(payload.amr) || payload.amr.length > 16 || !payload.amr.every(value => typeof value === 'string') ||
          !payload.amr.includes('mfa')) throw new Error('MFA or identity claims unavailable');
      // Roles are resolved from the private database registry on every request,
      // not from user-controlled JWT profile fields or a consumer app identity.
      return Object.freeze({ issuer: payload.iss, subject: payload.sub });
    } catch {
      // Provider errors may contain tokens or key data. Do not log or relay them.
      throw new OperatorError('operator_authentication_required');
    }
  }
}
