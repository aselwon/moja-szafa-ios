import { execFile } from 'node:child_process';
import { gzipSync } from 'node:zlib';

const uuid = value => typeof value === 'string' && /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/.test(value);
const deny = () => { throw new Error('export_access_denied'); };
export const MAX_ARCHIVE_BYTES = 256 * 1024 * 1024;

// Minimal POSIX ustar, fixed safe names and permissions; no shell or dependencies.
export function tarEntry(name, bytes) {
  if (!/^(data\.json|photos\/[a-f0-9-]{36}\.jpg)$/.test(name)) deny();
  const header = Buffer.alloc(512);
  header.write(name, 0, 100);
  const octal = (n, offset, size) => header.write(n.toString(8).padStart(size - 1, '0') + '\0', offset, size);
  octal(0o600, 100, 8); octal(0, 108, 8); octal(0, 116, 8);
  octal(bytes.length, 124, 12); octal(0, 136, 12);
  header.fill(32, 148, 156); header.write('0', 156); header.write('ustar\0', 257); header.write('00', 263);
  octal(header.reduce((sum, byte) => sum + byte, 0), 148, 8);
  return Buffer.concat([header, bytes, Buffer.alloc((512 - bytes.length % 512) % 512)]);
}

export class ExportService {
  constructor({ store, images }) { Object.assign(this, { store, images }); }
  async command(action, owner, id) {
    if (!uuid(owner) || !uuid(id)) deny();
    const result = await this.store.call(action, { owner, id });
    if (!result) deny();
    return result;
  }
  request(owner, id) { return this.command('request', owner, id); }
  async download(owner, id) {
    const snapshot = structuredClone(await this.command('read', owner, id));
    const entries = [];
    let total = 0;
    const append = (name, bytes) => {
      total += bytes.length + 1024;
      if (total > MAX_ARCHIVE_BYTES) throw new Error('export_too_large');
      entries.push(tarEntry(name, bytes));
    };
    for (const photo of snapshot.garment_images) {
      const match = /^([a-f0-9-]{36})\/(original|thumbnail)\.jpg$/.exec(photo.object_key);
      if (!match || !uuid(photo.id)) throw new Error('export_image_unavailable');
      // Existing pipeline checks live ownership, deletion and readiness twice.
      const token = await this.images.downloadToken(owner, match[1], match[2]);
      const { bytes } = await this.images.download(owner, token, match[2]);
      delete photo.object_key;
      photo.path = `photos/${photo.id}.jpg`;
      append(photo.path, bytes);
    }
    append('data.json', Buffer.from(JSON.stringify(snapshot, null, 2)));
    const bytes = gzipSync(Buffer.concat([...entries, Buffer.alloc(1024)]));
    // Never release an expired snapshot or one whose account was deleted while assembling.
    await this.command('check', owner, id);
    return bytes;
  }
  sweep() { return this.store.call('sweep', {}); }
}

export function postgresExports() {
  return { call(action, data) {
    const encoded = Buffer.from(JSON.stringify({ ...data, action })).toString('base64');
    return new Promise((resolve, reject) => {
      const child = execFile('psql', ['-X', '-q', '-t', '-A', '-v', 'ON_ERROR_STOP=1'],
        { timeout: 30_000, maxBuffer: 32 * 1024 * 1024 }, (error, stdout) => {
          if (error) return reject(new Error('export_store_unavailable'));
          try { resolve(JSON.parse(stdout)); } catch { reject(new Error('export_store_unavailable')); }
        });
      child.stdin.on('error', () => {});
      // All table projections share a transaction snapshot. Serialization failures
      // fail closed; callers retry the same operation UUID.
      child.stdin.end(`BEGIN ISOLATION LEVEL REPEATABLE READ; SELECT app.exports_command(convert_from(decode('${encoded}','base64'),'UTF8')::jsonb); COMMIT;`);
    });
  } };
}
