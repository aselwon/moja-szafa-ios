import { execFile } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { Readable } from 'node:stream';
import { pipeline } from 'node:stream/promises';
import { createGzip } from 'node:zlib';

const uuid = value => typeof value === 'string' && /^[a-f0-9]{8}(-[a-f0-9]{4}){3}-[a-f0-9]{12}$/.test(value);
const denied = () => { throw new Error('export_unavailable'); };

export function postgresExports() {
  const query = sql => new Promise((resolve, reject) => {
    const child = execFile('psql', ['-X', '-q', '-t', '-A', '-v', 'ON_ERROR_STOP=1'],
      { timeout: 30_000, maxBuffer: 32 * 1024 * 1024 }, (error, stdout) => {
        if (error) return reject(new Error('export_unavailable'));
        try { resolve(stdout.trim() ? JSON.parse(stdout) : null); }
        catch { reject(new Error('export_unavailable')); }
      });
    child.stdin.on('error', () => {});
    child.stdin.end(sql);
  });
  const identities = (owner, id) => { if (!uuid(owner) || !uuid(id)) denied(); };
  return {
    snapshot(owner, id) {
      identities(owner, id);
      return query(`SELECT app.export_snapshot('${owner}'::uuid,'${id}'::uuid);`);
    },
    authorized(owner, id, photo = null) {
      identities(owner, id);
      // Encode private key on stdin, not command arguments; no SQL interpolation.
      if (photo && !uuid(photo.id)) denied();
      const key = photo ? Buffer.from(photo.object_key).toString('base64') : '';
      return query(`SELECT to_json(app.export_access('${owner}'::uuid,'${id}'::uuid,
        ${photo ? `'${photo.id}'::uuid` : 'NULL'},convert_from(decode('${key}','base64'),'UTF8')));`);
    }
  };
}

// POSIX ustar, regular files only, generated ASCII paths. No shell/archive tools.
function* entry(name, bytes) {
  if (!/^(data\.json|photos\/[a-f0-9-]{36}\.(jpg|png|heic|webp))$/.test(name)) denied();
  const header = Buffer.alloc(512);
  const octal = (value, offset, width) => header.write(value.toString(8).padStart(width - 1, '0') + '\0', offset, width, 'ascii');
  header.write(name, 0, 100, 'ascii');
  octal(0o600, 100, 8); octal(0, 108, 8); octal(0, 116, 8);
  octal(bytes.length, 124, 12); octal(0, 136, 12);
  header.fill(32, 148, 156); header.write('0', 156); header.write('ustar\0', 257); header.write('00', 263);
  const sum = header.reduce((a, b) => a + b, 0);
  header.write(sum.toString(8).padStart(6, '0') + '\0 ', 148, 8, 'ascii');
  yield header; yield bytes;
  if (bytes.length % 512) yield Buffer.alloc(512 - bytes.length % 512);
}

export class DataExport {
  constructor({ store, storage }) { Object.assign(this, { store, storage }); }
  async snapshot(owner, id) {
    if (!uuid(owner) || !uuid(id)) denied();
    const result = await this.store.snapshot(owner, id);
    if (!result) denied();
    return result;
  }
  async *archive(owner, id, snapshot) {
    // Keys stay server-side. JSON references only generated archive-relative names.
    const photos = snapshot.photos.map(photo => {
      if (!uuid(photo.id) || !/^[a-f0-9-]{36}\/(original|thumbnail|cleaned)\.(jpg|png|heic|webp)$/.test(photo.object_key)) denied();
      return { ...photo, path: `photos/${photo.id}.${photo.object_key.split('.').at(-1)}` };
    });
    const json = { ...snapshot, photos: photos.map(({ object_key, ...photo }) => photo) };
    yield* entry('data.json', Buffer.from(JSON.stringify(json)));
    for (const photo of photos) {
      // Revalidate deletion/expiry and exact ownership immediately before and after I/O.
      const check = async () => {
        if (!await this.store.authorized(owner, id, photo)) denied();
      };
      await check();
      const bytes = await this.storage.get(photo.object_key);
      await check();
      yield* entry(photo.path, bytes);
    }
    if (!await this.store.authorized(owner, id)) denied();
    yield Buffer.alloc(1024);
  }
}

// Mount on the same TLS gateway as RPC. Auth must verify session and account.
// Apply per-owner concurrency/rate limits and disable proxy buffering/access-body logs.
export function exportHandler(service, authenticate) {
  if (typeof authenticate !== 'function') throw new Error('verified_authenticator_required');
  return async (request, response) => {
    const requestID = randomUUID();
    try {
      const owner = await authenticate(request.headers.authorization);
      const match = /^\/v1\/exports\/([a-f0-9-]{36})$/.exec(request.url);
      if (request.method !== 'GET' || !match || !owner) denied();
      const snapshot = await service.snapshot(owner, match[1]);
      response.writeHead(200, { 'Content-Type': 'application/gzip', 'Cache-Control': 'private, no-store',
        'Content-Disposition': 'attachment; filename="moja-szafa.tar.gz"', 'X-Content-Type-Options': 'nosniff' });
      // pipeline observes backpressure and disconnects; never stores an archive copy.
      await pipeline(Readable.from(service.archive(owner, match[1], snapshot)), createGzip(), response);
    } catch {
      if (response.headersSent) { response.destroy(); return; }
      response.writeHead(404, { 'Content-Type': 'application/json', 'Cache-Control': 'private, no-store' });
      response.end(JSON.stringify({ code: 'export_unavailable', message: 'Export unavailable or expired', request_id: requestID }));
    }
  };
}
