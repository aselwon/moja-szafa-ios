import { randomUUID } from 'node:crypto';

// Mount on the authenticated gateway origin. Never accept owner IDs in the body.
export function exportHandler(service, authenticate) {
  if (typeof authenticate !== 'function') throw new Error('verified_authenticator_required');
  return async (request, response) => {
    const requestID = randomUUID();
    const json = (status, value) => {
      response.writeHead(status, { 'Content-Type': 'application/json', 'Cache-Control': 'private, no-store' });
      response.end(JSON.stringify(value));
    };
    try {
      const owner = await authenticate(request.headers.authorization);
      if (!owner) return json(401, { code: 'unauthorized', message: 'Sign in required', request_id: requestID });
      const path = new URL(request.url, 'https://private.invalid').pathname;
      const match = /^\/v1\/exports\/([a-f0-9-]{36})(\/archive)?$/.exec(path);
      if (!match) return json(404, { code: 'not_found', message: 'Not found', request_id: requestID });
      if (request.method === 'POST' && !match[2]) return json(200, await service.request(owner, match[1]));
      if (request.method === 'GET' && match[2]) {
        const bytes = await service.download(owner, match[1]);
        // Check session again after potentially slow image reads.
        if (await authenticate(request.headers.authorization) !== owner) throw new Error('export_access_denied');
        response.writeHead(200, { 'Content-Type': 'application/gzip', 'Cache-Control': 'private, no-store',
          'Content-Disposition': 'attachment; filename="moja-szafa.tar.gz"', 'X-Content-Type-Options': 'nosniff' });
        return response.end(bytes);
      }
      json(405, { code: 'method_not_allowed', message: 'Method not allowed', request_id: requestID });
    } catch (error) {
      const code = ['export_access_denied', 'export_too_large'].includes(error.message) ? error.message : 'export_unavailable';
      json(code === 'export_access_denied' ? 403 : code === 'export_too_large' ? 413 : 503,
        { code, message: 'Export could not be completed', request_id: requestID });
    }
  };
}
