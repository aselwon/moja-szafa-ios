import { randomUUID } from 'node:crypto';
import { MAX_BYTES } from './pipeline.mjs';

// Supply verifyIdentity from the deployed Auth gateway. It must validate issuer,
// audience, signature, expiry and revocation and return the user UUID, or throw.
// No default verifier and no server listener with an unauthenticated fallback.
export function imageHandler(pipeline, verifyIdentity) {
  if (typeof verifyIdentity !== 'function') throw new Error('image_auth_required');
  return async (request, response) => {
    const request_id = randomUUID();
    response.setHeader('Cache-Control', 'private, no-store');
    response.setHeader('X-Content-Type-Options', 'nosniff');
    const json = (status, body) => {
      response.writeHead(status, { 'Content-Type': 'application/json' });
      response.end(JSON.stringify(body));
    };
    try {
      const owner = await verifyIdentity(request);
      const url = new URL(request.url, 'https://private.invalid');
      let result;
      if (request.method === 'GET' && url.pathname === '/v1/images/read') {
        result = await pipeline.read(owner, url.searchParams.get('token'), url.searchParams.get('variant'));
        response.writeHead(200, { 'Content-Type': result.content_type });
        response.end(result.bytes);
        return;
      }
      if (request.method !== 'POST') throw new Error('image_access_denied');
      const limit = url.pathname === '/v1/images/upload' ? MAX_BYTES : 4096;
      if (Number(request.headers['content-length'] ?? 0) > limit) throw new Error('image_size_invalid');
      request.setTimeout(30_000, () => request.destroy());
      let size = 0;
      const chunks = [];
      for await (const chunk of request) {
        size += chunk.length;
        if (size > limit) throw new Error('image_size_invalid');
        chunks.push(chunk);
      }
      const bytes = Buffer.concat(chunks);
      if (url.pathname === '/v1/images/upload') {
        result = await pipeline.upload(owner, url.searchParams.get('token'), bytes);
      } else {
        const body = JSON.parse(bytes);
        if (url.pathname === '/v1/images/begin') result = await pipeline.begin(owner, body.garment_id, body.operation_id);
        else if (url.pathname === '/v1/images/read-token') result = await pipeline.readToken(owner, body.id, body.variant);
        else throw new Error('image_access_denied');
      }
      json(200, { data: result, request_id });
    } catch {
      // Do not reflect storage errors, URL signatures, filenames or decoder data.
      if (!response.headersSent) json(400, { error: { code: 'image_request_rejected', message: 'Image request could not be completed', request_id } });
      else response.destroy();
    }
  };
}
