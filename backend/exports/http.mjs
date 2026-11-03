import { randomUUID } from 'node:crypto';
import { createReadStream } from 'node:fs';
import { pipeline } from 'node:stream/promises';

// Mount on the authenticated TLS gateway, same origin as the iOS API base URL.
// authenticate verifies signature, issuer, audience, expiry AND current session.
export function exportHandler(service, authenticate) {
  if (typeof authenticate !== 'function') throw new Error('verified_authenticator_required');
  return async (request, response) => {
    const requestID = randomUUID();
    const json = (status, value) => {
      response.writeHead(status, { 'Content-Type': 'application/json', 'Cache-Control': 'private, no-store' });
      response.end(JSON.stringify(value));
    };
    let archive, timer;
    try {
      const owner = await authenticate(request.headers.authorization);
      if (!owner) return json(401, { code: 'unauthorized', message: 'Sign in required', request_id: requestID });
      const url = new URL(request.url, 'https://private.invalid');
      const route = /^\/v1\/exports\/([a-f0-9-]{36})(\/archive)?$/.exec(url.pathname);
      if (!route || url.search || !['POST','GET'].includes(request.method)) {
        return json(404, { code: 'not_found', message: 'Not found', request_id: requestID });
      }
      if (request.method === 'POST' && !route[2]) return json(200, await service.prepare(owner, route[1]));
      if (request.method !== 'GET' || !route[2]) return json(404, { code: 'not_found', message: 'Not found', request_id: requestID });
      archive = await service.archive(owner, route[1]);
      // Revalidate the session after potentially slow archive preparation.
      if (await authenticate(request.headers.authorization) !== owner) throw new Error('export_unavailable');
      await service.check(owner, route[1]);
      const remaining = archive.expiresAt - Date.now();
      if (remaining <= 0) throw new Error('export_unavailable');
      timer = setTimeout(() => response.destroy(), remaining);
      response.writeHead(200, { 'Content-Type': 'application/x-tar', 'Content-Length': archive.size,
        'Content-Disposition': 'attachment; filename="moja-szafa.tar"',
        'Cache-Control': 'private, no-store', 'X-Content-Type-Options': 'nosniff' });
      await pipeline(createReadStream(archive.path), response);
    } catch (error) {
      if (response.headersSent) response.destroy();
      else json(error.message === 'export_too_large' ? 413 : 503, {
        code: error.message === 'export_too_large' ? 'export_too_large' : 'export_unavailable',
        message: 'Export could not be completed. Retry or request a new export after expiry.', request_id: requestID
      });
    } finally {
      clearTimeout(timer);
      if (archive) await archive.cleanup();
    }
  };
}
