import { createServer } from 'node:http';
import { randomUUID } from 'node:crypto';
import { AsyncLocalStorage } from 'node:async_hooks';
import { GatewayError, bearer, normalizeEmail, sessionToken } from './managed-auth.mjs';
import { ImagePipeline } from '../images/pipeline.mjs';
import { imageHandler } from '../images/http.mjs';
import { DataExports } from '../exports/service.mjs';
import { exportHandler } from '../exports/http.mjs';
import { weatherHandler } from '../weather/http.mjs';
import { SubscriptionVerificationError } from './subscriptions/verification.mjs';
import { DeletionReauthentication } from './deletion-reauth.mjs';

const uuid = value => typeof value === 'string' && /^[a-f0-9]{8}(-[a-f0-9]{4}){3}-[a-f0-9]{12}$/i.test(value);
async function jsonBody(request, limit = 16384) {
  if (request.headers['content-type']?.split(';', 1)[0].trim() !== 'application/json') throw new GatewayError('invalid_request', 400);
  let size = 0;
  const chunks = [];
  for await (const chunk of request) {
    size += chunk.length;
    if (size > limit) throw new GatewayError('request_too_large', 413);
    chunks.push(chunk);
  }
  try {
    const value = JSON.parse(Buffer.concat(chunks).toString('utf8'));
    if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Error();
    return value;
  } catch { throw new GatewayError('invalid_request', 400); }
}
function fields(value, expected) {
  if (Object.keys(value).sort().join(',') !== expected.sort().join(',')) throw new GatewayError('invalid_request', 400);
}
function sessionDTO(principal) {
  return { userID: principal.owner, accessToken: principal.token, refreshToken: principal.token, expiresAt: principal.expiresAt };
}

export function createGateway({ auth, store, storage, signingKey, exportDirectory, forecast, metrics, subscriptions, deletionEnabled = false, now = () => Date.now() }) {
  const deletion = deletionEnabled ? new DeletionReauthentication({ auth, store }) : null;
  const context = new AsyncLocalStorage();
  const authenticate = async header => {
    const principal = await auth.current(bearer(header));
    await store.session(principal);
    context.getStore().principal = principal;
    return principal.owner;
  };
  const commands = kind => ({ call: (action, data) => {
    const principal = context.getStore()?.principal;
    if (!principal) throw new GatewayError('unauthorized', 401);
    return store.command(principal, kind, action, data);
  } });
  const images = storage && signingKey ? imageHandler(new ImagePipeline({ store: commands('images'), storage, signingKey }), authenticate) : null;
  const purchaseImages = storage && signingKey ? imageHandler(new ImagePipeline({ store: commands('purchase_images'), storage, signingKey }), authenticate, { prefix: '/v1/purchase-images', parentField: 'candidate_id' }) : null;
  const recognitionImages = storage && signingKey ? imageHandler(new ImagePipeline({ store: commands('recognition_images'), storage, signingKey }), authenticate, { prefix: '/v1/recognition-images', parentField: 'draft_id' }) : null;
  const exports = storage && exportDirectory ? exportHandler(new DataExports({
    store: commands('exports'), storage, directory: exportDirectory, maxBytes: 512 * 1024 ** 2,
  }), authenticate) : null;
  const weather = forecast ? weatherHandler({ authenticate, forecast }) : null;
  // Bounded abuse protection complements managed OTP limits and durable per-email limits.
  const starts = new Map();
  const subscriptionAttempts = new Map();
  const admitSubscription = key => {
    for (const [id, entry] of subscriptionAttempts) if (entry.until <= now()) subscriptionAttempts.delete(id);
    const entry = subscriptionAttempts.get(key) ?? { count: 0, until: now() + 60000 };
    if (entry.count >= 60 || (!subscriptionAttempts.has(key) && subscriptionAttempts.size >= 10000)) throw new GatewayError('rate_limited', 429);
    entry.count++; subscriptionAttempts.set(key, entry);
  };
  let active = 0;
  const server = createServer((request, response) => context.run({}, async () => {
    const requestID = randomUUID();
    const started = process.hrtime.bigint();
    let metricRoute = 'unknown'; let rpcError = false; let measured = false;
    const measure = aborted => {
      if (measured) return;
      measured = true;
      metrics?.record({ route: metricRoute, method: request.method, status: response.statusCode,
        durationMs: Number(process.hrtime.bigint() - started) / 1e6, aborted, rpcError });
    };
    response.once('finish', () => measure(false));
    response.once('close', () => measure(!response.writableFinished));
    const send = (status, value) => {
      rpcError = Boolean(value?.error);
      response.writeHead(status, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store',
        'X-Content-Type-Options': 'nosniff', 'X-Request-ID': requestID });
      response.end(JSON.stringify(value));
    };
    if (active >= 32) return send(503, { error: { code: 'busy', message: 'Try again later', request_id: requestID } });
    active++;
    try {
      const url = new URL(request.url, 'http://gateway.invalid');
      metricRoute = metrics?.route(url.pathname) ?? 'unknown';
      if (url.search && !url.pathname.startsWith('/v1/images/') && !url.pathname.startsWith('/v1/purchase-images/') && !url.pathname.startsWith('/v1/recognition-images/')) throw new GatewayError('invalid_request', 400);
      if (request.method === 'GET' && url.pathname === '/health') return send(200, { status: 'ok' });
      if (url.pathname === '/v1/account/deletion' || url.pathname === '/v1/account/deletion/challenge' || url.pathname === '/v1/account/deletion/status') {
        if (!deletion || request.method !== 'POST') throw new GatewayError('deletion_unavailable', 503);
        if (url.pathname.endsWith('/status')) {
          const input = await jsonBody(request);
          const principal = input?.receipt_token === undefined ? await auth.current(bearer(request.headers.authorization)) : null;
          return send(200, await deletion.status(principal, input));
        }
        const principal = await auth.current(bearer(request.headers.authorization));
        if (url.pathname.endsWith('/challenge')) {
          // Existing native client sends an empty body. Reject arbitrary payloads.
          let size = 0;
          for await (const chunk of request) { size += chunk.length; if (size > 0) throw new GatewayError('invalid_request', 400); }
          return send(200, await deletion.start(principal));
        }
        return send(202, await deletion.confirm(principal, await jsonBody(request)));
      }
      if (url.pathname.startsWith('/auth/v1/')) {
        if (request.method !== 'POST') throw new GatewayError('not_found', 404);
        const body = await jsonBody(request);
        if (url.pathname === '/auth/v1/email/start') {
          fields(body, ['email']);
          const email = normalizeEmail(body.email);
          const key = request.socket.remoteAddress; // Do not trust a caller's X-Forwarded-For.
          for (const [address, entry] of starts) if (entry.until <= now()) starts.delete(address);
          const entry = starts.get(key) ?? { count: 0, until: now() + 3600000 };
          if (entry.count >= 20 || (!starts.has(key) && starts.size >= 10000)) throw new GatewayError('rate_limited', 429);
          entry.count++; starts.set(key, entry);
          const challengeID = await store.challenge(email);
          await auth.sendOTP(email);
          return send(200, { challengeID });
        }
        if (url.pathname === '/auth/v1/email/verify') {
          fields(body, ['challengeID', 'code']);
          if (!uuid(body.challengeID)) throw new GatewayError('invalid_request', 400);
          const email = await store.attempt(body.challengeID);
          const principal = await auth.verifyOTP(email, body.code);
          if (principal.email !== email) { await auth.logout(principal.token).catch(() => {}); throw new GatewayError('unauthorized', 401); }
          try { await store.session(principal); await store.consume(body.challengeID); }
          catch (error) { await auth.logout(principal.token).catch(() => {}); throw error; }
          return send(200, sessionDTO(principal));
        }
        if (url.pathname === '/auth/v1/refresh') {
          fields(body, ['refreshToken']);
          const principal = await auth.current(sessionToken(body.refreshToken));
          await store.session(principal);
          return send(200, sessionDTO(principal));
        }
        if (url.pathname === '/auth/v1/logout') {
          fields(body, ['refreshToken']);
          await auth.logout(sessionToken(body.refreshToken));
          return send(200, {});
        }
        // Apple is not silently replaced with another provider or a fake identity.
        throw new GatewayError('authentication_not_configured', 503);
      }
      if (url.pathname === '/v1/weather' && weather) return await weather(request, response);
      if (url.pathname === '/v1/subscriptions/apple-notifications' && request.method === 'POST') {
        if (!subscriptions) throw new GatewayError('subscriptions_unavailable', 503);
        admitSubscription(`webhook:${request.socket.remoteAddress}`);
        const body = await jsonBody(request, 35000); fields(body, ['signedPayload']);
        const event = await subscriptions.notification(body.signedPayload);
        if (!event.test) await store.receiveSubscription(null, event);
        // Apple retries unavailable storage; erased identities are intentionally
        // acknowledged without recreating a profile or retaining the receipt.
        return send(200, {});
      }
      if (url.pathname.startsWith('/v1/subscriptions/')) {
        const owner = await authenticate(request.headers.authorization);
        if (!subscriptions) throw new GatewayError('subscriptions_unavailable', 503);
        const principal = context.getStore().principal;
        if (request.method === 'GET' && url.pathname === '/v1/subscriptions/catalog') {
          const catalog = subscriptions.catalog();
          // Preflight also proves that the subscription schema and narrow role
          // are available; environment variables alone must not enable charging.
          await store.subscriptionStatus(principal, catalog.environment);
          return send(200, catalog);
        }
        if (request.method === 'GET' && url.pathname === '/v1/subscriptions/status') {
          return send(200, { entitlements: await store.subscriptionStatus(principal, subscriptions.catalog().environment) });
        }
        if (request.method === 'POST' && url.pathname === '/v1/subscriptions/transactions') {
          admitSubscription(`account:${owner}`);
          const body = await jsonBody(request, 35000); fields(body, ['signedTransaction']);
          const event = await subscriptions.transaction(body.signedTransaction, owner);
          const result = await store.receiveSubscription(principal, event);
          if (result?.error) throw new GatewayError('account_unavailable', 401);
          return send(200, result);
        }
        throw new GatewayError('not_found', 404);
      }
      const rpc = /^\/rest\/v1\/rpc\/(api_v1_[a-z_]+)$/.exec(url.pathname);
      if (rpc && request.method === 'POST') {
        if (!store.operations.has(rpc[1])) throw new GatewayError('not_found', 404);
        if (request.headers['content-profile'] && request.headers['content-profile'] !== 'app') throw new GatewayError('invalid_request', 400);
        const body = await jsonBody(request, 1024 * 1024);
        fields(body, ['request']);
        await authenticate(request.headers.authorization);
        return send(200, await store.rpc(context.getStore().principal, rpc[1], body.request));
      }
      if (url.pathname.startsWith('/v1/purchase-images/') && purchaseImages) return await purchaseImages(request, response);
      if (url.pathname.startsWith('/v1/recognition-images/') && recognitionImages) return await recognitionImages(request, response);
      if (url.pathname.startsWith('/v1/images/') && images) return await images(request, response);
      if (url.pathname.startsWith('/v1/exports/') && exports) return await exports(request, response);
      throw new GatewayError('not_found', 404);
    } catch (error) {
      if (response.headersSent) response.destroy();
      else {
        const safe = error instanceof GatewayError || error instanceof SubscriptionVerificationError;
        send(safe ? error.status : 503, { error: { code: safe ? error.code : 'service_unavailable',
          message: 'Request could not be completed', request_id: requestID } });
      }
    } finally { active--; }
  }));
  server.requestTimeout = 30000;
  server.headersTimeout = 10000;
  server.keepAliveTimeout = 5000;
  server.maxHeadersCount = 50;
  return server;
}
