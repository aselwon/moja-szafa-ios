import { createHash, createHmac, timingSafeEqual, randomUUID } from 'node:crypto';
import { execFile } from 'node:child_process';
import { mkdir, readFile, writeFile, unlink } from 'node:fs/promises';
import { resolve, join } from 'node:path';

export const MAX_BYTES = 20 * 1024 * 1024;
const uuid = value => typeof value === 'string' && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value);
function deny() { throw new Error('image_access_denied'); }

// Call only with identity from verified authentication, never a request-body owner.
// Signatures are additionally bound to that identity: possession of a URL alone
// does not authorize access. Keys and signed tokens must not enter access logs.
export class ImagePipeline {
  constructor({ secret, ledger, objects, decode, now = () => Date.now() }) {
    if (!Buffer.isBuffer(secret) || secret.length < 32) throw new Error('image_signing_key_required');
    Object.assign(this, { secret, ledger, objects, decode, now });
  }
  sign(owner, id, action, lifetime) {
    const body = Buffer.from(JSON.stringify({ owner, id, action, exp: this.now() + lifetime })).toString('base64url');
    return `${body}.${createHmac('sha256', this.secret).update(body).digest('base64url')}`;
  }
  verify(owner, token, action) {
    if (!uuid(owner) || typeof token !== 'string' || token.length > 1024) deny();
    const parts = token.split('.');
    if (parts.length !== 2) deny();
    const expected = createHmac('sha256', this.secret).update(parts[0]).digest();
    const actual = Buffer.from(parts[1], 'base64url');
    if (actual.length !== expected.length || !timingSafeEqual(actual, expected)) deny();
    let claims;
    try { claims = JSON.parse(Buffer.from(parts[0], 'base64url')); } catch { deny(); }
    if (claims.owner !== owner || claims.action !== action || !uuid(claims.id) ||
        !Number.isSafeInteger(claims.exp) || claims.exp <= this.now()) deny();
    return claims.id;
  }
  async begin(owner, garment, operation) {
    if (![owner, garment, operation].every(uuid)) deny();
    const row = await this.ledger.call('begin', { owner, garment, operation });
    return { id: row.id, token: this.sign(owner, row.id, 'upload', 300_000), expires_in: 300 };
  }
  async upload(owner, token, bytes) {
    const id = this.verify(owner, token, 'upload');
    // HTTP ingress must also cap streamed bodies before allocating a Buffer.
    if (!Buffer.isBuffer(bytes) || bytes.length === 0 || bytes.length > MAX_BYTES) throw new Error('image_size_invalid');
    const row = await this.ledger.call('upload', { owner, id, digest: createHash('sha256').update(bytes).digest('hex') });
    if (row.state === 'ready') return { id }; // response lost after commit
    const output = await this.decode(bytes);
    for (const variant of ['original', 'thumbnail']) {
      if (!Buffer.isBuffer(output[variant]) || output[variant].length === 0 || output[variant].length > MAX_BYTES) {
        throw new Error('image_decoder_invalid');
      }
    }
    // Every key is durable BEFORE bytes are written. Never persist raw EXIF.
    await this.objects.put(row.original_key, output.original);
    await this.objects.put(row.thumbnail_key, output.thumbnail);
    await this.ledger.call('finish', { owner, id, original_bytes: output.original.length, thumbnail_bytes: output.thumbnail.length });
    return { id };
  }
  async readToken(owner, id, variant) {
    if (!uuid(owner) || !uuid(id) || !['original', 'thumbnail'].includes(variant)) deny();
    await this.ledger.call('read', { owner, id });
    return { token: this.sign(owner, id, variant, 60_000), expires_in: 60 };
  }
  async read(owner, token, variant) {
    if (!['original', 'thumbnail'].includes(variant)) deny();
    const id = this.verify(owner, token, variant);
    const row = await this.ledger.call('read', { owner, id });
    return { bytes: await this.objects.get(row[`${variant}_key`]), content_type: 'image/png', cache_control: 'private, no-store' };
  }
  async sweep() {
    const rows = await this.ledger.call('sweep', {});
    // Rows survive cleanup and account deletion. Repeated deletion repairs a
    // crash, partial write or late fenced writer; no unrecoverable in-memory list.
    for (const row of rows) {
      await this.objects.remove(row.original_key);
      await this.objects.remove(row.thumbnail_key);
      await this.ledger.call('swept', { id: row.id });
    }
    return rows.length;
  }
}

// Private worker-volume adapter. Never mount this directory in a web server.
// Storage services can implement the same get/put/remove contract; no public URL.
export function privateFiles(directory) {
  const root = resolve(directory);
  const path = key => {
    if (!/^[0-9a-f-]{36}\/(original|thumbnail)\.png$/.test(key)) deny();
    return join(root, key);
  };
  return {
    async put(key, bytes) {
      const target = path(key);
      await mkdir(resolve(target, '..'), { recursive: true, mode: 0o700 });
      // Write once. A retry cannot replace content referenced by a ready image.
      // Atomic link publishes only a fully written file.
      const { link } = await import('node:fs/promises');
      const temporary = `${target}.${randomUUID()}.tmp`;
      // Temp data lives only for this process; crash leftovers are addressed by
      // the volume cleanup procedure documented alongside this adapter.
      try {
        await writeFile(temporary, bytes, { mode: 0o600, flag: 'wx' });
        try { await link(temporary, target); } catch (error) { if (error.code !== 'EEXIST') throw error; }
      } finally { await unlink(temporary).catch(error => { if (error.code !== 'ENOENT') throw error; }); }
    },
    get: key => readFile(path(key)),
    async remove(key) {
      const target = path(key);
      await unlink(target).catch(error => { if (error.code !== 'ENOENT') throw error; });
      const { readdir } = await import('node:fs/promises');
      const directory = resolve(target, '..');
      const name = key.split('/')[1];
      const files = await readdir(directory).catch(error => { if (error.code === 'ENOENT') return []; throw error; });
      for (const file of files.filter(file => file.startsWith(name + '.') && file.endsWith('.tmp'))) {
        await unlink(join(directory, file)).catch(error => { if (error.code !== 'ENOENT') throw error; });
      }
    }
  };
}

export function imageIODecoder(executable) {
  return bytes => new Promise((resolveResult, reject) => {
    const child = execFile(executable, [], { timeout: 30_000, killSignal: 'SIGKILL', maxBuffer: 60 * 1024 * 1024 }, (error, stdout) => {
      if (error) return reject(new Error('image_decode_failed'));
      try {
        const result = JSON.parse(stdout);
        resolveResult({ original: Buffer.from(result.original, 'base64'), thumbnail: Buffer.from(result.thumbnail, 'base64') });
      } catch { reject(new Error('image_decode_failed')); }
    });
    child.stdin.on('error', () => {});
    child.stdin.end(bytes);
  });
}

export function postgresImageLedger() {
  return { call(action, data) {
    const payload = Buffer.from(JSON.stringify({ action, ...data })).toString('base64');
    return new Promise((resolveResult, reject) => {
      const child = execFile('psql', ['-X', '-q', '-t', '-A', '-v', 'ON_ERROR_STOP=1'],
        { timeout: 10_000, maxBuffer: 1024 * 1024 }, (error, stdout) => {
          if (error) return reject(new Error('image_ledger_failed'));
          try { resolveResult(JSON.parse(stdout)); } catch { reject(new Error('image_ledger_failed')); }
        });
      child.stdin.on('error', () => {});
      child.stdin.end(`SELECT app.images_command(convert_from(decode('${payload}','base64'),'UTF8')::jsonb);`);
    });
  } };
}
