import assert from 'node:assert/strict';
import { mkdtemp, readFile, readdir, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { DataExports } from '../exports/service.mjs';
import { exportHandler } from '../exports/http.mjs';

const owner = '00000000-0000-0000-0000-000000000001';
const other = '00000000-0000-0000-0000-000000000002';
const id = '00000000-0000-0000-0000-000000000003';
const image = '00000000-0000-0000-0000-000000000004';
const directory = await mkdtemp(join(tmpdir(), 'export-test-'));
let now = 1000, reads = 0, live = true;
const expiry = 901000;
const snapshot = { schema_version: 1,
  garments: [{ id, price_grosz: '9223372036854775807', currency: 'PLN' }],
  wear_events: [{ worn_on: '2020-01-02' }], planned_outfits: [{ planned_on: '2030-01-01' }],
  garment_images: [{ id: image, garment_id: id, content_type: 'image/jpeg', object_key: 'private/path' }] };
const store = { async call(action, args) {
  if (action === 'sweep') return true;
  if (args.owner !== owner || args.id !== id || now >= expiry || !live) return null;
  if (action === 'image') return args.image === image && args.key === 'private/path';
  return { id, expires_at: new Date(expiry).toISOString(), ...(action === 'read' ? { snapshot } : {}) };
} };
const storage = { async get(key) { assert.equal(key, 'private/path'); reads++; return Buffer.from('photo fixture'); } };
const service = new DataExports({ store, storage, directory, clock: () => now });
try {
  assert.deepEqual(await service.prepare(owner, id), await service.prepare(owner, id));
  await assert.rejects(service.prepare(other, id));
  await assert.rejects(service.archive(other, id));
  assert.equal(reads, 0);
  const archive = await service.archive(owner, id);
  // Independent standard-library tar reader checks checksum, paths and bytes.
  const result = JSON.parse((await promisify(execFile)('python3', ['-c', `
import json,tarfile,sys
with tarfile.open(sys.argv[1]) as t:
    data=json.load(t.extractfile('data.json'))
    assert t.extractfile('photos/${image}.jpg').read()==b'photo fixture'
    assert all(m.isfile() and '..' not in m.name for m in t.getmembers())
    print(json.dumps(data))
`, archive.path], { encoding: 'utf8' })).stdout);
  assert.equal(result.garments[0].price_grosz, '9223372036854775807');
  assert.equal(result.wear_events[0].worn_on, '2020-01-02');
  assert.equal(result.planned_outfits[0].planned_on, '2030-01-01');
  assert(!JSON.stringify(result).includes('private/path'));
  assert.equal((await readFile(archive.path)).length, archive.size);
  await archive.cleanup();
  assert.deepEqual(await readdir(directory), []);
  now = expiry;
  await assert.rejects(service.archive(owner, id));
  now = 1000;
  const failing = new DataExports({ store, directory, clock: () => now,
    storage: { async get() { throw new Error('private storage detail'); } } });
  await assert.rejects(failing.archive(owner, id));
  assert.deepEqual(await readdir(directory), []);
  const expiresDuringRead = new DataExports({ store, directory, clock: () => now,
    storage: { async get() { now = expiry; return Buffer.from('photo'); } } });
  await assert.rejects(expiresDuringRead.archive(owner, id));
  assert.deepEqual(await readdir(directory), []);
  now = 1000;
  const revoked = new DataExports({ store, directory, clock: () => now,
    storage: { async get() { live = false; return Buffer.from('photo'); } } });
  await assert.rejects(revoked.archive(owner, id));
  assert.deepEqual(await readdir(directory), []);
  live = true;
  const small = new DataExports({ store, storage, directory, clock: () => now, maxBytes: 512 });
  await assert.rejects(small.archive(owner, id), /export_too_large/);
  assert.deepEqual(await readdir(directory), []);
  const response = () => ({ writeHead(status, headers) { this.status = status; this.headers = headers; },
    end(bytes) { this.body = JSON.parse(bytes); } });
  let res = response();
  await exportHandler(service, async () => null)({ headers: {}, method: 'POST', url: `/v1/exports/${id}` }, res);
  assert.equal(res.status, 401);
  res = response();
  await exportHandler(service, async () => other)({ headers: {}, method: 'POST', url: `/v1/exports/${id}` }, res);
  assert.equal(res.status, 503);
  assert.equal(res.headers['Cache-Control'], 'private, no-store');
  assert(res.body.request_id);
  assert(!JSON.stringify(res.body).includes(owner));
  res = response();
  await exportHandler(service, async () => owner)({ headers: {}, method: 'POST', url: `/v1/exports/${id}` }, res);
  assert.equal(res.status, 200);
  assert.equal(res.body.id, id);
  console.log('PASS: private export archive, exact prices, photos, ownership, expiry, failure cleanup and HTTP errors');
} finally { await rm(directory, { recursive: true, force: true }); }
