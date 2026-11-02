import assert from 'node:assert/strict';
import { Readable } from 'node:stream';
import { imageHandler } from '../images/http.mjs';
import { randomBytes } from 'node:crypto';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { promisify } from 'node:util';
import { execFile } from 'node:child_process';
import { ImagePipeline, privateFiles, decodeImage, MAX_BYTES } from '../images/pipeline.mjs';

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
  await service.upload(owner, prepared.upload_token, input);
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
