import assert from 'node:assert/strict';
import { gzipSync, gunzipSync } from 'node:zlib';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { DataExport, exportHandler } from '../exports/export.mjs';

const owner = '00000000-0000-0000-0000-000000000001';
const other = '00000000-0000-0000-0000-000000000002';
const id = '00000000-0000-0000-0000-000000000003';
const photoID = '00000000-0000-0000-0000-000000000004';
let available = true;
let photoAvailable = true;
let reads = 0;
const snapshot = { schema_version: 1, garments: [{ id, price_grosz: "9223372036854775807" }, { price_grosz: null }],
  wear_events: [{ worn_on: '2026-01-01', timezone: 'Europe/Warsaw' }],
  planned_outfits: [{ planned_on: '2027-01-01' }],
  photos: [{ id: photoID, garment_id: id, variant: 'original', object_key: `${id}/original.jpg` }] };
const store = { async snapshot(who, ticket) {
  if (who !== owner || ticket !== id || !available) return null;
  return { ...snapshot, photos: photoAvailable ? snapshot.photos : [] };
}, async authorized(who, ticket, photo = null) {
  return who === owner && ticket === id && available && (!photo ||
    (photoAvailable && snapshot.photos.some(p => p.id === photo.id && p.object_key === photo.object_key)));
} };
const storage = { async get(key) { reads++; assert.equal(key, `${id}/original.jpg`); return Buffer.from('photo fixture'); } };
const service = new DataExport({ store, storage });
const collect = async iterable => { const chunks = []; for await (const chunk of iterable) chunks.push(chunk); return Buffer.concat(chunks); };
const tar = await collect(service.archive(owner, id, await service.snapshot(owner, id)));
// Independently parse with Python's standard archive library (no dependencies).
const parsed = JSON.parse((await promisify(execFile)('python3', ['-c', `
import tarfile,io,json,sys,base64
with tarfile.open(fileobj=io.BytesIO(base64.b64decode(sys.argv[1])),mode='r:gz') as t:
 print(json.dumps({'names':t.getnames(),'data':json.load(t.extractfile('data.json')),'photo':t.extractfile('${`photos/${photoID}.jpg`}').read().decode()}))
`, gzipSync(tar).toString('base64')], { timeout: 5000 })).stdout);
assert.deepEqual(parsed.names, ['data.json', `photos/${photoID}.jpg`]);
assert.equal(parsed.data.garments[0].price_grosz, "9223372036854775807");
assert.equal(parsed.data.garments[1].price_grosz, null);
assert.equal(parsed.data.wear_events[0].worn_on, '2026-01-01');
assert.equal(parsed.data.planned_outfits[0].planned_on, '2027-01-01');
assert.equal(parsed.photo, 'photo fixture');
assert(!JSON.stringify(parsed.data).includes('object_key'));
assert.deepEqual(gunzipSync(gzipSync(tar)), tar);
await assert.rejects(service.snapshot(other, id), /export_unavailable/);
await assert.rejects(service.snapshot(owner, '../secret'), /export_unavailable/);
available = false;
await assert.rejects(service.snapshot(owner, id), /export_unavailable/);
await assert.rejects(collect(service.archive(owner, id, snapshot)), /export_unavailable/);
available = true;
photoAvailable = false;
const before = reads;
await assert.rejects(collect(service.archive(owner, id, snapshot)), /export_unavailable/);
assert.equal(reads, before);
photoAvailable = true;
const slow = new DataExport({ store, storage: { async get() { available = false; return Buffer.from('bytes'); } } });
await assert.rejects(collect(slow.archive(owner, id, snapshot)), /export_unavailable/);
available = true;
const malicious = { ...snapshot, photos: [{ ...snapshot.photos[0], object_key: '../../secrets' }] };
await assert.rejects(collect(service.archive(owner, id, malicious)), /export_unavailable/);
const missing = new DataExport({ store, storage: { async get() { throw new Error('missing'); } } });
await assert.rejects(collect(missing.archive(owner, id, snapshot)), /missing/);
let status, headers, responseBody;
const response = { writeHead(s, h) { status = s; headers = h; }, end(b) { responseBody = JSON.parse(b); } };
await exportHandler(service, async () => other)({ method: 'GET', url: `/v1/exports/${id}`, headers: {} }, response);
assert.equal(status, 404);
assert.equal(headers['Cache-Control'], 'private, no-store');
assert.equal(responseBody.code, 'export_unavailable');
assert(responseBody.request_id);
assert(!JSON.stringify(responseBody).includes(owner));
assert.throws(() => exportHandler(service), /verified_authenticator_required/);
console.log('PASS: T016 archive contents, safe paths, owner isolation, expiry, deletion, missing photos and private HTTP failures');
