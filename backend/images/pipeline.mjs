import { createHmac, timingSafeEqual } from 'node:crypto';
import { execFile } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { mkdir, open, readFile, rm } from 'node:fs/promises';
import { resolve } from 'node:path';

export const MAX_BYTES = 12 * 1024 * 1024;
const uuid = value => typeof value === 'string' && /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/.test(value);
const fail = () => { throw new Error('image_access_denied'); };

export function decodeImage(bytes) {
  if (!Buffer.isBuffer(bytes) || !bytes.length || bytes.length > MAX_BYTES) throw new Error('image_limit');
  return new Promise((resolve, reject) => {
    const child = execFile('python3', [fileURLToPath(new URL('./normalize.py', import.meta.url))],
      { timeout: 15_000, killSignal: 'SIGKILL', maxBuffer: 32 * 1024 * 1024 }, (error, stdout) => {
        if (error) return reject(new Error('image_rejected'));
        try { resolve(JSON.parse(stdout)); } catch { reject(new Error('image_rejected')); }
      });
    child.stdin.on('error', () => {});
    child.stdin.end(bytes);
  });
}

// Private persistent volume adapter: never mount this directory under a web root.
// The service is the only reader; there is deliberately no public object URL.
export function privateFiles(directory) {
  const root = resolve(directory);
  const path = key => {
    if (!/^[a-f0-9-]{36}\/(original|thumbnail)\.jpg$/.test(key)) fail();
    return resolve(root, key);
  };
  return {
    async put(key, bytes) {
      const destination = path(key);
      await mkdir(resolve(destination, '..'), { recursive: true, mode: 0o700 });
      const file = await open(destination, 'w', 0o600);
      try { await file.writeFile(bytes); await file.sync(); } finally { await file.close(); }
      // Persist directory entries before committing ready metadata in PostgreSQL.
      for (const directory of [resolve(destination, '..'), root]) {
        const handle = await open(directory, 'r');
        try { await handle.sync(); } finally { await handle.close(); }
      }
    },
    get: key => readFile(path(key)),
    remove: key => rm(path(key), { force: true })
  };
}

// identity is supplied ONLY by a gateway after verifying the session, never by
// request JSON. A stolen signed URL alone cannot authorize upload or download.
export class ImagePipeline {
  constructor({ store, storage, signingKey, clock = () => Date.now(), decode = decodeImage }) {
    if (!Buffer.isBuffer(signingKey) || signingKey.length < 32) throw new Error('image_signing_key_required');
    Object.assign(this, { store, storage, signingKey, clock, decode });
  }
  sign(owner, id, action) {
    const body = Buffer.from(JSON.stringify({ owner, id, action, exp: this.clock() + 60_000 })).toString('base64url');
    return `${body}.${createHmac('sha256', this.signingKey).update(body).digest('base64url')}`;
  }
  verify(identity, token, action) {
    try {
      if (!uuid(identity) || typeof token !== 'string' || token.length > 1024) fail();
      const [body, signature, extra] = token.split('.');
      const expected = createHmac('sha256', this.signingKey).update(body).digest();
      const actual = Buffer.from(signature, 'base64url');
      if (extra !== undefined || actual.length !== expected.length || !timingSafeEqual(actual, expected)) fail();
      const claims = JSON.parse(Buffer.from(body, 'base64url'));
      if (claims.owner !== identity || claims.action !== action || !uuid(claims.id) ||
          !Number.isSafeInteger(claims.exp) || claims.exp <= this.clock()) fail();
      return claims.id;
    } catch { fail(); }
  }
  async prepare(identity, garment, operation) {
    if (![identity, garment, operation].every(uuid)) fail();
    const row = await this.store.call('prepare', { owner: identity, garment, id: operation });
    if (!row) fail();
    return { image_id: row.id, upload_token: this.sign(identity, row.id, 'upload'), expires_in: 60,
      max_bytes: MAX_BYTES, content_types: ['image/jpeg', 'image/png', 'image/webp'] };
  }
  async upload(identity, token, bytes) {
    const id = this.verify(identity, token, 'upload');
    if (!Buffer.isBuffer(bytes) || !bytes.length || bytes.length > MAX_BYTES) throw new Error('image_limit');
    const claim = await this.store.call('claim', { owner: identity, id });
    if (!claim) fail();
    if (claim.state === 'ready') return { image_id: id }; // Post-commit retry.
    const images = await this.decode(bytes);
    for (const variant of ['original', 'thumbnail']) {
      await this.storage.put(`${id}/${variant}.jpg`, Buffer.from(images[variant].data, 'base64'));
    }
    const completed = await this.store.call('finish', { owner: identity, id, fence: claim.fence });
    if (!completed) fail();
    return { image_id: id };
  }
  async downloadToken(identity, id, variant = 'thumbnail') {
    if (!uuid(identity) || !uuid(id) || !['original', 'thumbnail'].includes(variant)) fail();
    if (!await this.store.call('read', { owner: identity, id })) fail();
    return this.sign(identity, id, `read:${variant}`);
  }
  async download(identity, token, variant = 'thumbnail') {
    const id = this.verify(identity, token, `read:${variant}`);
    if (!['original', 'thumbnail'].includes(variant) || !await this.store.call('read', { owner: identity, id })) fail();
    const bytes = await this.storage.get(`${id}/${variant}.jpg`);
    // Recheck expiration after storage latency; never return cacheable responses.
    this.verify(identity, token, `read:${variant}`);
    if (!await this.store.call('read', { owner: identity, id })) fail();
    return { bytes, headers: { 'Content-Type': 'image/jpeg', 'Cache-Control': 'private, no-store',
      'X-Content-Type-Options': 'nosniff' } };
  }
  async sweep() {
    const rows = await this.store.call('sweep', {});
    for (const row of rows) {
      for (const variant of ['original', 'thumbnail']) await this.storage.remove(`${row.id}/${variant}.jpg`);
      await this.store.call('cleaned', { id: row.id });
    }
    return rows.length;
  }
}

// Uses existing libpq credentials; no secrets or private payloads on argv/logs.
export function postgresImages() {
  return { call(action, data) {
    const encoded = Buffer.from(JSON.stringify({ ...data, action })).toString('base64');
    return new Promise((resolve, reject) => {
      const child = execFile('psql', ['-X', '-q', '-t', '-A', '-v', 'ON_ERROR_STOP=1'],
        { timeout: 10_000, maxBuffer: 1024 * 1024 }, (error, stdout) => {
          if (error) return reject(new Error('image_store_unavailable'));
          try { resolve(JSON.parse(stdout)); } catch { reject(new Error('image_store_unavailable')); }
        });
      child.stdin.on('error', () => {});
      child.stdin.end(`SELECT app.images_command(convert_from(decode('${encoded}','base64'),'UTF8')::jsonb);`);
    });
  } };
}
