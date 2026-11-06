// Managed Better Auth owns OTP generation, verification, sessions and revocation.
// We transport its signed session cookie; we never mint or sign authentication tokens.
const COOKIE = '__Secure-neon-auth.session_token';
const UUID = /^[a-f0-9]{8}(-[a-f0-9]{4}){3}-[a-f0-9]{12}$/i;
const TOKEN = /^[A-Za-z0-9._~%+\/=-]{20,4096}$/;
export class GatewayError extends Error {
  constructor(code, status = 503) { super(code); this.code = code; this.status = status; }
}
export function sessionToken(value) {
  if (typeof value !== 'string' || !TOKEN.test(value)) throw new GatewayError('unauthorized', 401);
  return value;
}
export function bearer(header) {
  if (typeof header !== 'string' || !header.startsWith('Bearer ')) throw new GatewayError('unauthorized', 401);
  return sessionToken(header.slice(7));
}
export function normalizeEmail(value) {
  if (typeof value !== 'string' || value.length > 254) throw new GatewayError('invalid_request', 400);
  const email = value.trim().toLowerCase();
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email) || /[\x00-\x1f\x7f]/.test(email)) {
    throw new GatewayError('invalid_request', 400);
  }
  return email;
}
async function limitedJSON(response) {
  if (!response.body) throw new GatewayError('authentication_unavailable');
  const reader = response.body.getReader();
  const chunks = [];
  let size = 0;
  try {
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      size += value.byteLength;
      if (size > 128 * 1024) throw new GatewayError('authentication_unavailable');
      chunks.push(Buffer.from(value));
    }
    return JSON.parse(Buffer.concat(chunks).toString('utf8'));
  } catch { await reader.cancel().catch(() => {}); throw new GatewayError('authentication_unavailable'); }
}
export class ManagedAuth {
  constructor({ baseURL, fetchImpl = globalThis.fetch, timeoutMs = 10000, now = () => Date.now() }) {
    const url = new URL(baseURL);
    if (url.protocol !== 'https:' || url.username || url.password || url.search || url.hash ||
        !url.hostname.endsWith('.neon.tech') || !url.pathname.endsWith('/auth')) {
      throw new Error('invalid_managed_auth_url');
    }
    this.baseURL = url.href.replace(/\/$/, '');
    this.fetch = fetchImpl;
    this.timeoutMs = timeoutMs;
    this.now = now;
  }
  async request(path, { token, body } = {}) {
    const headers = { Accept: 'application/json', Origin: new URL(this.baseURL).origin };
    // Never forward arbitrary browser cookies, session_data caches or caller-selected origins.
    if (token) headers.Cookie = `${COOKIE}=${sessionToken(token)}`;
    if (body !== undefined) headers['Content-Type'] = 'application/json';
    let response;
    try {
      response = await this.fetch(this.baseURL + path, {
        method: body === undefined ? 'GET' : 'POST', headers,
        body: body === undefined ? undefined : JSON.stringify(body),
        redirect: 'error', signal: AbortSignal.timeout(this.timeoutMs),
      });
    } catch { throw new GatewayError('authentication_unavailable'); }
    if (!response.ok) {
      await response.body?.cancel().catch(() => {});
      if (response.status === 429) throw new GatewayError('rate_limited', 429);
      if ([400, 401, 403, 422].includes(response.status)) throw new GatewayError('authentication_rejected', 401);
      throw new GatewayError('authentication_unavailable');
    }
    const data = await limitedJSON(response);
    let renewed;
    for (const cookie of response.headers.getSetCookie()) {
      const pair = cookie.split(';', 1)[0];
      if (pair.startsWith(`${COOKIE}=`) && pair.length > COOKIE.length + 1) renewed = sessionToken(pair.slice(COOKIE.length + 1));
    }
    return { data, token: renewed ?? token };
  }
  async sendOTP(email) {
    const { data } = await this.request('/email-otp/send-verification-otp', { body: { email: normalizeEmail(email), type: 'sign-in' } });
    if (data?.success !== true) throw new GatewayError('authentication_unavailable');
  }
  async verifyOTP(email, code) {
    if (typeof code !== 'string' || !/^\d{4,10}$/.test(code)) throw new GatewayError('authentication_rejected', 401);
    const result = await this.request('/sign-in/email-otp', { body: { email: normalizeEmail(email), otp: code } });
    if (!result.token) throw new GatewayError('authentication_unavailable');
    return this.current(result.token);
  }
  async current(token) {
    const result = await this.request('/get-session?disableCookieCache=true', { token: sessionToken(token) });
    const { session, user } = result.data ?? {};
    const expiresAt = Date.parse(session?.expiresAt);
    if (!UUID.test(user?.id ?? '') || !UUID.test(session?.id ?? '') || session.userId !== user.id ||
        user.emailVerified !== true || user.banned === true || session.impersonatedBy ||
        !Number.isFinite(expiresAt) || expiresAt <= this.now()) throw new GatewayError('unauthorized', 401);
    return { owner: user.id, sessionID: session.id, email: normalizeEmail(user.email),
      token: result.token, expiresAt: Math.floor(expiresAt / 1000) };
  }
  async logout(token) {
    const { data } = await this.request('/sign-out', { token: sessionToken(token), body: {} });
    if (data?.success !== true) throw new GatewayError('authentication_unavailable');
  }
}
