import assert from 'node:assert/strict';
import test from 'node:test';
import { mkdtemp, rm, readFile, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { ImagePipeline, privateFiles, MAX_BYTES } from '../images/pipeline.mjs';

const owner = '00000000-0000-0000-0000-000000000001';
const other = '00000000-0000-0000-0000-000000000002';
const id = '00000000-0000-0000-0000-000000000003';
function fixture() {
  let time = 1000;
  const row = { id, state: 'pending', original_key: `${id}/original.png`, thumbnail_key: `${id}/thumbnail.png` };
  const files = new Map();
  let deleted = false;
  const ledger = { async call(action, data) {
    if (action === 'sweep') return deleted ? [row] : [];
    if (action === 'swept') return {};
    if (data.owner !== owner || deleted) throw new Error('denied');
    if (action === 'read' && row.state !== 'ready') throw new Error('pending');
    if (action === 'finish') row.state = 'ready';
    return row;
  } };
  const pipeline = new ImagePipeline({ secret: Buffer.alloc(32, 7), ledger,
    objects: { put: async (k, b) => files.set(k, b), get: async k => files.get(k), remove: async k => files.delete(k) },
    decode: async bytes => { if (bytes.toString() !== 'fixture') throw new Error('decode'); return { original: Buffer.from('clean'), thumbnail: Buffer.from('small') }; },
    now: () => time });
  return { pipeline, files, row, advance: n => { time += n; }, delete: () => { deleted = true; } };
}

test('owner-bound upload and reads reject tampering, wrong verb/variant and expiry at boundary', async () => {
  const f = fixture();
  const { token } = await f.pipeline.begin(owner, id, id);
  await assert.rejects(f.pipeline.upload(other, token, Buffer.from('fixture')));
  await assert.rejects(f.pipeline.upload(owner, token + 'x', Buffer.from('fixture')));
  await assert.rejects(f.pipeline.read(owner, token, 'original'));
  await f.pipeline.upload(owner, token, Buffer.from('fixture'));
  const read = await f.pipeline.readToken(owner, id, 'original');
  assert.equal((await f.pipeline.read(owner, read.token, 'original')).bytes.toString(), 'clean');
  await assert.rejects(f.pipeline.read(other, read.token, 'original'));
  await assert.rejects(f.pipeline.read(owner, read.token, 'thumbnail'));
  f.advance(60_000);
  await assert.rejects(f.pipeline.read(owner, read.token, 'original'));
  f.advance(240_000);
  await assert.rejects(f.pipeline.upload(owner, token, Buffer.from('fixture')));
});
test('malformed, oversized and empty uploads never publish bytes; pending is unreadable', async () => {
  const f = fixture();
  const { token } = await f.pipeline.begin(owner, id, id);
  for (const data of [Buffer.alloc(0), Buffer.alloc(MAX_BYTES + 1), Buffer.from('corrupt')]) {
    await assert.rejects(f.pipeline.upload(owner, token, data));
  }
  assert.equal(f.files.size, 0);
  await assert.rejects(f.pipeline.readToken(owner, id, 'original'));
});
test('lost response replay, immediate deletion revocation and repeatable cleanup', async () => {
  const f = fixture();
  const { token } = await f.pipeline.begin(owner, id, id);
  await f.pipeline.upload(owner, token, Buffer.from('fixture'));
  await f.pipeline.upload(owner, token, Buffer.from('fixture'));
  assert.equal(f.files.size, 2);
  const read = await f.pipeline.readToken(owner, id, 'original');
  f.delete();
  await assert.rejects(f.pipeline.read(owner, read.token, 'original'));
  await f.pipeline.sweep();
  assert.equal(f.files.size, 0);
  f.files.set(f.row.original_key, Buffer.from('late write'));
  await f.pipeline.sweep();
  assert.equal(f.files.size, 0);
});
test('private file adapter prevents path traversal, overwrite and removes crash temporaries', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'images-'));
  try {
    const files = privateFiles(directory);
    const key = `${id}/original.png`;
    await files.put(key, Buffer.from('first'));
    await files.put(key, Buffer.from('second'));
    assert.equal((await files.get(key)).toString(), 'first');
    await assert.rejects(files.put('../escape', Buffer.from('bad')));
    const temp = join(directory, key + '.crash.tmp');
    await writeFile(temp, 'crash');
    await files.remove(key);
    await assert.rejects(readFile(temp));
    await files.remove(key);
  } finally { await rm(directory, { recursive: true, force: true }); }
});

test('partial storage failure leaves no readable result and can be retried', async () => {
  const f = fixture();
  const { token } = await f.pipeline.begin(owner, id, id);
  const put = f.pipeline.objects.put;
  let fail = true;
  f.pipeline.objects.put = async (key, bytes) => {
    if (key.endsWith('thumbnail.png') && fail) throw new Error('storage unavailable');
    await put(key, bytes);
  };
  await assert.rejects(f.pipeline.upload(owner, token, Buffer.from('fixture')));
  assert.equal(f.files.size, 1);
  assert.equal(f.row.state, 'pending');
  await assert.rejects(f.pipeline.readToken(owner, id, 'original'));
  fail = false;
  await f.pipeline.upload(owner, token, Buffer.from('fixture'));
  assert.equal(f.files.size, 2);
  assert.equal(f.row.state, 'ready');
});

test('HTTP boundary requires authentication, caps streamed bodies and redacts errors', async () => {
  const { Readable } = await import('node:stream');
  const { imageHandler } = await import('../images/http.mjs');
  assert.throws(() => imageHandler(fixture().pipeline));
  let calls = 0;
  const handler = imageHandler({ begin: async () => { calls++; throw new Error('PRIVATE_INTERNAL_DETAIL'); } }, async () => owner);
  async function invoke(chunks, authenticatedHandler = handler) {
    const request = Readable.from(chunks);
    Object.assign(request, { method: 'POST', url: '/v1/images/begin', headers: {}, setTimeout() {} });
    const response = { headers: {}, setHeader(k, v) { this.headers[k] = v; },
      writeHead(status) { this.status = status; this.headersSent = true; }, end(body) { this.body = body; } };
    await authenticatedHandler(request, response);
    return response;
  }
  const tooLarge = await invoke([Buffer.alloc(4097)]);
  assert.equal(calls, 0);
  assert.equal(tooLarge.status, 400);
  const rejected = await invoke([Buffer.from('{}')]);
  assert.equal(calls, 1);
  assert.equal(rejected.headers['Cache-Control'], 'private, no-store');
  const error = JSON.parse(rejected.body).error;
  assert.equal(error.code, 'image_request_rejected');
  assert.match(error.request_id, /^[0-9a-f-]{36}$/);
  assert(!rejected.body.includes('PRIVATE_INTERNAL_DETAIL'));
  await invoke([Buffer.from('{}')], imageHandler({}, async () => { throw new Error('invalid JWT'); }));
  assert.equal(calls, 1);
});
