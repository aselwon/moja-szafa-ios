import assert from 'node:assert/strict';
import { Readable } from 'node:stream';
import { imageHandler } from '../images/http.mjs';
import { randomBytes } from 'node:crypto';
import { mkdtemp, rm, readdir } from 'node:fs/promises';
import { createServer, request as httpRequest } from 'node:http';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { promisify } from 'node:util';
import { execFile } from 'node:child_process';
import { ImagePipeline, privateFiles, decodeImage, MAX_BYTES, splitImagePair, MAX_PAIR_BYTES, PAIR_CONTENT_TYPE } from '../images/pipeline.mjs';

const owner = '00000000-0000-0000-0000-000000000001';
const other = '00000000-0000-0000-0000-000000000002';
const id = '00000000-0000-0000-0000-000000000003';
let now = 1000;
let state = 'pending';
let live = true;
let decodeCount = 0;
const store = { async call(action, data) {
  if (action === 'sweep') { state = 'retired'; return [{ id }]; }
  if (action === 'cleaned') return true;
  if (!live || data.owner !== owner || data.id !== id) return null;
  if (action === 'prepare') return { id };
  if (action === 'read') return state === 'ready';
  if (action === 'claim') {
    if (state === 'ready') return { state };
    if (state !== 'pending') return null;
    state = 'processing'; return { state, fence: id };
  }
  if (action === 'finish') { state = 'ready'; return true; }
} };
const directory = await mkdtemp(join(tmpdir(), 'wardrobe-images-'));
try {
  const storage = privateFiles(directory);
  const service = new ImagePipeline({ store, storage, signingKey: randomBytes(32), clock: () => now,
    decode: bytes => { decodeCount++; return decodeImage(bytes); } });
  const fixture = await promisify(execFile)('python3', ['-c',
    'from PIL import Image; import io,base64; b=io.BytesIO(); Image.new("RGB",(640,480),"red").save(b,"PNG"); print(base64.b64encode(b.getvalue()).decode())']);
  const input = Buffer.from(fixture.stdout.trim(), 'base64');
  const prepared = await service.prepare(owner, other, id);
  await assert.rejects(service.upload(other, prepared.upload_token, input), /access_denied/);
  await assert.rejects(service.upload(null, prepared.upload_token, input), /access_denied/);
  await assert.rejects(service.upload(owner, prepared.upload_token + '.extra', input), /access_denied/);
  await assert.rejects(service.upload(owner, prepared.upload_token, Buffer.alloc(MAX_BYTES + 1)), /image_limit/);
  await assert.rejects(service.downloadToken(owner, id), /access_denied/);
  // A real TCP disconnect before the complete body must not consume the upload
  // operation or publish partial files. Retry the same capability after reconnect.
  const received = Promise.withResolvers();
  const handled = Promise.withResolvers();
  let firstRequest = true;
  const handler = imageHandler(service, async header => header === 'owner-session' ? owner : null);
  const server = createServer((request, response) => {
    const interrupted = firstRequest;
    firstRequest = false;
    if (interrupted) request.once('data', received.resolve);
    const work = handler(request, response);
    if (interrupted) work.then(handled.resolve, handled.reject);
    else work.catch(error => response.destroy(error));
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const deadline = async promise => {
    let timer;
    try {
      return await Promise.race([promise, new Promise((_, reject) => {
        timer = setTimeout(() => reject(new Error('interrupted upload did not settle')), 5000);
      })]);
    } finally { clearTimeout(timer); }
  };
  try {
    const url = `http://127.0.0.1:${server.address().port}/v1/images/uploads/${id}?token=${prepared.upload_token}`;
    const partial = httpRequest(url, { method: 'PUT', headers: {
      authorization: 'owner-session', 'content-length': input.length,
      'content-type': 'application/octet-stream'
    } });
    partial.on('error', () => {}); // Deliberate connection reset.
    partial.write(input.subarray(0, Math.floor(input.length / 2)));
    await deadline(received.promise);
    partial.destroy();
    await deadline(handled.promise);
    assert.equal(state, 'pending', 'partial transport must not claim the operation');
    assert.equal(decodeCount, 0, 'partial bytes must not reach the decoder');
    assert.deepEqual(await readdir(directory), [], 'partial bytes must not enter private storage');
    const retry = await fetch(url, { method: 'PUT', headers: {
      authorization: 'owner-session', 'content-type': 'application/octet-stream'
    }, body: input, signal: AbortSignal.timeout(5000) });
    assert.equal(retry.status, 200);
    assert.equal((await retry.json()).image_id, id);
    assert.equal(state, 'ready');
  } finally {
    server.closeAllConnections();
    await new Promise(resolve => server.close(resolve));
  }
  await service.upload(owner, prepared.upload_token, input);
  assert.equal(decodeCount, 1, 'post-commit replay does not decode or overwrite');
  async function http(method, url, authorization, payload = '') {
    const request = Readable.from([Buffer.from(payload)]);
    Object.assign(request, { method, url, headers: { authorization } });
    const response = { writeHead(status, headers) { this.status = status; this.headers = headers; },
      end(bytes) { this.bytes = bytes; } };
    await imageHandler(service, async header => header === 'owner-session' ? owner : null)(request, response);
    return response;
  }
  const issued = await http('POST', `/v1/images/${id}/thumbnail/url`, 'owner-session');
  assert.equal(issued.status, 200);
  const signedURL = JSON.parse(issued.bytes).url;
  assert.equal((await http('GET', signedURL)).status, 403);
  assert.equal((await http('GET', signedURL, 'owner-session')).status, 200);
  assert.equal((await http('GET', signedURL.replace(id, other), 'owner-session')).status, 403);
  assert.equal((await http('POST', '/v1/images/uploads', 'owner-session', '{')).status, 400);
  assert.equal((await http('POST', '/v1/images/uploads', 'owner-session', 'x'.repeat(4097))).status, 413);
  const token = await service.downloadToken(owner, id);
  const response = await service.download(owner, token);
  assert.equal(response.headers['Cache-Control'], 'private, no-store');
  assert.equal(response.bytes.readUInt16BE(0), 0xffd8);
  await assert.rejects(service.download(other, token), /access_denied/);
  await assert.rejects(service.download(owner, token, 'original'), /access_denied/);
  await assert.rejects(service.download(owner, prepared.upload_token), /access_denied/);
  live = false;
  await assert.rejects(service.download(owner, token), /access_denied/);
  live = true;
  now = 61_000; // Exact boundary, not just after expiry.
  await assert.rejects(service.download(owner, token), /access_denied/);
  await assert.rejects(service.upload(owner, prepared.upload_token, input), /access_denied/);
  assert.equal(await service.sweep(), 1);
  await assert.rejects(storage.get(`${id}/original.jpg`), /ENOENT/);
  await assert.rejects(storage.get(`${id}/thumbnail.jpg`), /ENOENT/);
  await service.sweep(); // Repeated deletion is safe after restart/lost acknowledgement.
  assert.throws(() => storage.get('../escape'), /access_denied/);
  await assert.rejects(decodeImage(Buffer.from('not an image')), /image_rejected/);
} finally { await rm(directory, { recursive: true, force: true }); }
console.log('OK: signed image capabilities, identity/expiry/revocation, real decoder, private storage and replay');

// Source and cleaned edit share one publication fence, never two competing uploads.
const pairDirectory = await mkdtemp(join(tmpdir(), 'wardrobe-pair-'));
try {
  const storage = privateFiles(pairDirectory);
  let ready = false, retired = false, publicationCount = 0, claimCount = 0;
  const pairStore = { async call(action, data) {
    if (action === 'sweep') { retired = true; return [{ id }]; }
    if (action === 'cleaned') return true;
    if (retired || data.owner !== owner) return null;
    if (action === 'prepare') return data.has_cleaned ? { id } : null;
    if (action === 'claim') { claimCount++; return { state: ready ? 'ready' : 'processing', fence: id, has_cleaned: true }; }
    if (action === 'finish') {
      for (const key of ['original.jpg', 'thumbnail.jpg', 'cleaned.png']) assert.ok((await storage.get(`${id}/${key}`)).length);
      publicationCount++; ready = true; return true;
    }
    if (action === 'read') return ready;
  } };
  const service = new ImagePipeline({ store: pairStore, storage, signingKey: randomBytes(32) });
  const fixture = await promisify(execFile)('python3', ['-c',
    'from PIL import Image; import io,base64; b=io.BytesIO(); Image.new("RGBA",(64,48),(255,0,0,64)).save(b,"PNG"); print(base64.b64encode(b.getvalue()).decode())']);
  const cleaned = Buffer.from(fixture.stdout.trim(), 'base64');
  const source = Buffer.from((await decodeImage(cleaned)).original.data, 'base64');
  const length = Buffer.alloc(4); length.writeUInt32BE(source.length);
  const pair = Buffer.concat([length, source, cleaned]);
  assert.deepEqual(splitImagePair(pair), [source, cleaned]);
  for (const malformed of [Buffer.alloc(4), Buffer.from([255,255,255,255,1,1]), Buffer.alloc(MAX_PAIR_BYTES + 1)]) {
    assert.throws(() => splitImagePair(malformed), /image_limit/);
  }
  const prepared = await service.prepare(owner, other, id, true);
  await assert.rejects(service.upload(owner, prepared.upload_token, source), /access_denied/);
  const request = Readable.from([pair]);
  Object.assign(request, { method: 'PUT', url: `/v1/images/uploads/${id}?token=${prepared.upload_token}`,
    headers: { authorization: 'owner-session', 'content-type': PAIR_CONTENT_TYPE } });
  const response = { writeHead(status, headers) { this.status = status; this.headers = headers; }, end(bytes) { this.bytes = bytes; } };
  await imageHandler(service, async header => header === 'owner-session' ? owner : null)(request, response);
  assert.equal(response.status, 200);
  assert.equal(JSON.parse(response.bytes).image_id, id);
  const originalToken = await service.downloadToken(owner, id, 'original');
  const editToken = await service.downloadToken(owner, id, 'cleaned');
  const original = await service.download(owner, originalToken, 'original');
  const edit = await service.download(owner, editToken, 'cleaned');
  assert.equal(original.headers['Content-Type'], 'image/jpeg');
  assert.equal(edit.headers['Content-Type'], 'image/png');
  assert.deepEqual(edit.bytes.subarray(0,8), Buffer.from([137,80,78,71,13,10,26,10]));
  await assert.rejects(service.download(other, editToken, 'cleaned'), /access_denied/);
  await service.upload(owner, prepared.upload_token, pair, true);
  assert.equal(publicationCount, 1, 'retry must not republish or replace either variant');
  assert.equal(claimCount, 3);
  await service.sweep();
  for (const key of ['original.jpg','thumbnail.jpg','cleaned.png']) await assert.rejects(storage.get(`${id}/${key}`), /ENOENT/);
  await assert.rejects(service.download(owner, editToken, 'cleaned'), /access_denied/);
} finally { await rm(pairDirectory, { recursive: true, force: true }); }

{
  const expired = new ImagePipeline({ store: { call: async () => ({ id, expired: true }) },
    storage: {}, signingKey: randomBytes(32) });
  const request = Readable.from([Buffer.from(JSON.stringify({ garment_id: other, operation_id: id }))]);
  Object.assign(request, { method: 'POST', url: '/v1/images/uploads', headers: { authorization: 'owner' } });
  const response = { writeHead(status) { this.status = status; }, end(bytes) { this.bytes = bytes; } };
  await imageHandler(expired, async () => owner)(request, response);
  assert.equal(response.status, 409);
  assert.equal(JSON.parse(response.bytes).code, 'image_upload_expired');
}
