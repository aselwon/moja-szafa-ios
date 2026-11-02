import assert from 'node:assert/strict';
import { gunzipSync } from 'node:zlib';
import { ExportService, tarEntry } from '../exports/service.mjs';
import { exportHandler } from '../exports/http.mjs';

const owner = '00000000-0000-0000-0000-000000000001';
const other = '00000000-0000-0000-0000-000000000002';
const id = '00000000-0000-0000-0000-000000000003';
const snapshot = { schema_version: 1, garments: [{ id, price_grosz: 12345 }],
  wear_events: [{ worn_on: '2026-10-31', timezone: 'Europe/Warsaw' }],
  planned_outfits: [{ planned_on: '2026-12-01' }],
  garment_images: [{ id, object_key: `${id}/original.jpg` }] };
let expired = false;
let deleted = false;
let reads = 0;
let expireOnRead = false;
let deleteOnRead = false;
const service = new ExportService({
  store: { async call(action, input) {
    if (input.owner !== owner || input.id !== id || expired || deleted) return null;
    return action === 'read' ? snapshot : { id, expires_at: '2026-11-03T00:00:00Z' };
  } },
  images: {
    async downloadToken(account, imageID, variant) {
      assert.equal(account, owner); assert.equal(imageID, id); assert.equal(variant, 'original'); return 'private';
    },
    async download() {
      reads++;
      if (expireOnRead) expired = true;
      if (deleteOnRead) deleted = true;
      return { bytes: Buffer.from('photo fixture') };
    }
  }
});
assert.deepEqual(await service.request(owner, id), await service.request(owner, id));
await assert.rejects(service.request(other, id), /access_denied/);
await assert.rejects(service.download(other, id), /access_denied/);
assert.equal(reads, 0);
const archive = gunzipSync(await service.download(owner, id));
const files = new Map();
for (let offset = 0; archive[offset];) {
  const header = archive.subarray(offset, offset + 512);
  const name = header.subarray(0, 100).toString().replace(/\0.*$/s, '');
  const size = parseInt(header.subarray(124, 136).toString(), 8);
  const checksum = parseInt(header.subarray(148, 156).toString(), 8);
  const copy = Buffer.from(header); copy.fill(32, 148, 156);
  assert.equal(checksum, copy.reduce((a, b) => a + b, 0));
  files.set(name, archive.subarray(offset + 512, offset + 512 + size));
  offset += 512 + Math.ceil(size / 512) * 512;
}
assert.equal(files.get(`photos/${id}.jpg`).toString(), 'photo fixture');
const exported = JSON.parse(files.get('data.json'));
assert.equal(exported.garments[0].price_grosz, 12345);
assert.equal(exported.wear_events[0].worn_on, '2026-10-31');
assert.equal(exported.planned_outfits[0].planned_on, '2026-12-01');
assert.equal(exported.garment_images[0].object_key, undefined);
assert.equal(exported.garment_images[0].path, `photos/${id}.jpg`);
assert(snapshot.garment_images[0].object_key); // no mutation of stored snapshot
assert.throws(() => tarEntry('../secret', Buffer.alloc(0)), /access_denied/);
expireOnRead = true;
await assert.rejects(service.download(owner, id), /access_denied/);
expireOnRead = false; expired = false; deleteOnRead = true;
await assert.rejects(service.download(owner, id), /access_denied/);
deleteOnRead = false; deleted = false;
const bad = new ExportService({ store: { call: async () => ({ garment_images: [{ id, object_key: '../secret' }] }) }, images: service.images });
await assert.rejects(bad.download(owner, id), /image_unavailable/);
const missing = new ExportService({ store: service.store, images: { downloadToken: async () => { throw new Error('missing'); } } });
await assert.rejects(missing.download(owner, id), /missing/); // no silently partial archive

async function http(auth, method, url) {
  const response = { writeHead(status, headers) { this.status = status; this.headers = headers; }, end(data) { this.data = data; } };
  await exportHandler(service, auth)({ headers: {}, method, url }, response);
  return response;
}
assert.equal((await http(async () => null, 'POST', `/v1/exports/${id}`)).status, 401);
assert.equal((await http(async () => other, 'GET', `/v1/exports/${id}/archive`)).status, 403);
const success = await http(async () => owner, 'GET', `/v1/exports/${id}/archive`);
assert.equal(success.status, 200);
assert.equal(success.headers['Cache-Control'], 'private, no-store');
let checks = 0;
assert.equal((await http(async () => ++checks === 1 ? owner : null, 'GET', `/v1/exports/${id}/archive`)).status, 403);
console.log('PASS: export archive, history/prices/plans, owner isolation, expiry/deletion during reads, missing images, session revocation and HTTP privacy');
