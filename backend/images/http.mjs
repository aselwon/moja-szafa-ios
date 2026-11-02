import { randomUUID } from 'node:crypto';
import { MAX_BYTES } from './pipeline.mjs';

async function body(request, limit) {
  if (request.headers['content-length'] && Number(request.headers['content-length']) > limit) {
    throw new Error('image_limit');
  }
  const chunks = [];
  let count = 0;
  for await (const chunk of request) {
    count += chunk.length;
    if (count > limit) throw new Error('image_limit');
    chunks.push(chunk);
  }
  return Buffer.concat(chunks);
}

// Mount behind TLS with header/body timeouts and per-account/concurrency limits.
// authenticate must verify issuer, audience, signature, expiry and session state.
// It receives only the Authorization header, never an owner supplied in JSON.
export function imageHandler(pipeline, authenticate) {
  if (typeof authenticate !== 'function') throw new Error('verified_authenticator_required');
  return async (request, response) => {
    const requestID = randomUUID();
    const json = (status, value) => {
      response.writeHead(status, { 'Content-Type': 'application/json', 'Cache-Control': 'private, no-store' });
      response.end(JSON.stringify(value));
    };
    try {
      const identity = await authenticate(request.headers.authorization);
      if (!identity) throw new Error('image_access_denied');
      const url = new URL(request.url, 'https://private.invalid');
      if (request.method === 'POST' && url.pathname === '/v1/images/uploads') {
        const input = JSON.parse((await body(request, 4096)).toString('utf8'));
        const prepared = await pipeline.prepare(identity, input.garment_id, input.operation_id);
        const { upload_token, ...metadata } = prepared;
        return json(200, { ...metadata, upload_url: `/v1/images/uploads/${prepared.image_id}?token=${upload_token}` });
      }
      const upload = /^\/v1\/images\/uploads\/([a-f0-9-]{36})$/.exec(url.pathname);
      if (request.method === 'PUT' && upload) {
        const token = url.searchParams.get('token');
        if (pipeline.verify(identity, token, 'upload') !== upload[1]) throw new Error('image_access_denied');
        return json(200, await pipeline.upload(identity, token, await body(request, MAX_BYTES)));
      }
      const image = /^\/v1\/images\/([a-f0-9-]{36})\/(original|thumbnail)(\/url)?$/.exec(url.pathname);
      if (image && request.method === 'POST' && image[3]) {
        const token = await pipeline.downloadToken(identity, image[1], image[2]);
        return json(200, { url: `/v1/images/${image[1]}/${image[2]}?token=${token}`, expires_in: 60 });
      }
      if (image && request.method === 'GET' && !image[3]) {
        const token = url.searchParams.get('token');
        if (pipeline.verify(identity, token, `read:${image[2]}`) !== image[1]) throw new Error('image_access_denied');
        const result = await pipeline.download(identity, token, image[2]);
        response.writeHead(200, result.headers);
        return response.end(result.bytes);
      }
      json(404, { code: 'not_found', message: 'Not found', request_id: requestID });
    } catch (error) {
      const code = ['image_limit', 'image_rejected', 'image_access_denied'].includes(error.message)
        ? error.message : error instanceof SyntaxError ? 'invalid_request' : 'image_unavailable';
      const status = { image_limit: 413, image_rejected: 422, image_access_denied: 403, invalid_request: 400, image_unavailable: 503 }[code];
      json(status, { code, message: 'Image request could not be completed', request_id: requestID });
    }
  };
}
