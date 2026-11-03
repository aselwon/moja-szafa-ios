import { randomUUID } from 'node:crypto';

export function deletionHandler(service, authenticate) {
  if (typeof authenticate !== 'function') throw new Error('verified_authenticator_required');
  return async (request, response) => {
    const requestID = randomUUID();
    const json = (status, value) => {
      response.writeHead(status, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' });
      response.end(JSON.stringify(value));
    };
    try {
      // Gateway may admit tombstoned sessions ONLY here for reauthenticated retry;
      // every other route, refresh and login must reject the deletion ledger.
      const owner = await authenticate(request.headers.authorization);
      if (!owner) return json(401, { code: 'unauthorized', message: 'Sign in required', request_id: requestID });
      if (request.method !== 'POST') throw new Error('invalid_request');
      if (request.url === '/v1/account/deletion/challenge') return json(200, await service.challenge(owner));
      if (request.url !== '/v1/account/deletion') throw new Error('invalid_request');
      let body = '';
      for await (const chunk of request) {
        body += chunk;
        if (Buffer.byteLength(body) > 16384) throw new Error('invalid_request');
      }
      const input = JSON.parse(body);
      return json(202, await service.request(owner, input.operation_id, input.proof));
    } catch (error) {
      const code = error.message === 'reauthentication_required' ? error.message : 'deletion_unavailable';
      json(code === 'reauthentication_required' ? 403 : 503, {
        code, message: 'Deletion could not be confirmed. Retry.', request_id: requestID
      });
    }
  };
}
