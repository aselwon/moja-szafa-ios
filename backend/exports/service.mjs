import { execFile } from 'node:child_process';
import { mkdir, mkdtemp, open, rm, readdir, stat } from 'node:fs/promises';
import { join } from 'node:path';

const uuid = value => typeof value === 'string' && /^[a-f0-9]{8}(-[a-f0-9]{4}){3}-[a-f0-9]{12}$/.test(value);
const denied = () => { throw new Error('export_unavailable'); };

// POSIX ustar, regular files only. Names are generated from validated UUIDs,
// never from garment names or private object keys. No external archiver needed.
function header(name, size) {
  if (Buffer.byteLength(name) > 100 || !Number.isSafeInteger(size) || size > 0o77777777777) denied();
  const block = Buffer.alloc(512);
  block.write(name, 0, 100);
  for (const [offset, length, value] of [[100,8,0o600],[108,8,0],[116,8,0],[124,12,size],[136,12,0]]) {
    block.write(value.toString(8).padStart(length - 1, '0') + '\0', offset, length);
  }
  block.fill(32, 148, 156);
  block.write('0', 156); block.write('ustar\0', 257); block.write('00', 263);
  block.write([...block].reduce((a, b) => a + b, 0).toString(8).padStart(6, '0') + '\0 ', 148);
  return block;
}

export class DataExports {
  constructor({ store, storage, directory, clock = () => Date.now(), maxBytes = 20 * 1024 ** 3 }) {
    Object.assign(this, { store, storage, directory, clock, maxBytes });
    this.active = new Set();
  }
  async command(action, owner, id, extra = {}) {
    if (!uuid(owner) || !uuid(id)) denied();
    const row = await this.store.call(action, { owner, id, ...extra });
    if (!row) denied();
    return row;
  }
  async prepare(owner, id) { return this.command('prepare', owner, id); }
  async check(owner, id) {
    const row = await this.command('check', owner, id);
    if (!(Date.parse(row.expires_at) > this.clock())) denied();
    return row;
  }
  async archive(owner, id) {
    if (this.active.has(owner) || this.active.size >= 2) throw new Error('export_unavailable');
    this.active.add(owner);
    let release;
    try {
      release = await this.storage.lockOwner?.(owner);
      const archive = await this.buildArchive(owner, id);
      const cleanup = archive.cleanup;
      archive.cleanup = async () => {
        try { await cleanup(); } finally { await release?.(); this.active.delete(owner); }
      };
      return archive;
    } catch (error) {
      await release?.();
      this.active.delete(owner);
      throw error;
    }
  }
  async buildArchive(owner, id) {
    const row = await this.command('read', owner, id);
    await this.check(owner, id);
    await mkdir(this.directory, { recursive: true, mode: 0o700 });
    const directory = await mkdtemp(join(this.directory, `export-${owner}-`));
    const path = join(directory, 'moja-szafa.tar');
    const cleanup = () => rm(directory, { recursive: true, force: true });
    let file;
    try {
      file = await open(path, 'wx', 0o600);
      let size = 0;
      const append = async bytes => {
        size += bytes.length;
        if (size > this.maxBytes) throw new Error('export_too_large');
        // FileHandle.write may perform a short write.
        for (let offset = 0; offset < bytes.length;) {
          const result = await file.write(bytes, offset, bytes.length - offset);
          if (!result.bytesWritten) throw new Error('export_unavailable');
          offset += result.bytesWritten;
        }
      };
      const entry = async (name, bytes) => {
        await append(header(name, bytes.length)); await append(bytes);
        await append(Buffer.alloc((512 - bytes.length % 512) % 512));
      };
      const snapshot = structuredClone(row.snapshot);
      const images = [...snapshot.garment_images.map(image => ({ image, folder: 'photos' })),
        ...(snapshot.purchase_images ?? []).map(image => ({ image, folder: 'purchase-photos' }))];
      const extensions = { 'image/jpeg': 'jpg', 'image/png': 'png', 'image/heic': 'heic', 'image/webp': 'webp' };
      for (const { image, folder } of images) {
        if (!uuid(image.id) || !extensions[image.content_type]) denied();
        const key = image.object_key;
        await this.command('image', owner, id, { image: image.id, key });
        const bytes = await this.storage.get(key);
        await this.check(owner, id);
        await this.command('image', owner, id, { image: image.id, key });
        image.archive_path = `${folder}/${image.id}.${extensions[image.content_type]}`;
        delete image.object_key;
        await entry(image.archive_path, bytes);
      }
      await entry('data.json', Buffer.from(JSON.stringify(snapshot, null, 2)));
      await append(Buffer.alloc(1024));
      await file.close(); file = undefined;
      await this.check(owner, id);
      return { path, cleanup, expiresAt: Date.parse(row.expires_at), size };
    } catch (error) {
      if (file) await file.close();
      await cleanup();
      throw error;
    }
  }
  // Run at startup and at least once/minute. Old ledger IDs remain as replay
  // tombstones, but payloads and crash-left spool files are erased.
  async sweep() {
    await this.store.call('sweep', {});
    await mkdir(this.directory, { recursive: true, mode: 0o700 });
    for (const name of await readdir(this.directory)) {
      if (!/^export-(?:[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}-)?[a-zA-Z0-9]+$/.test(name)) continue;
      const path = join(this.directory, name);
      if ((await stat(path)).mtimeMs + 15 * 60_000 <= this.clock()) await rm(path, { recursive: true, force: true });
    }
  }
}

export function postgresExports() {
  return { call(action, data) {
    const encoded = Buffer.from(JSON.stringify({ ...data, action })).toString('base64');
    return new Promise((resolve, reject) => {
      const child = execFile('psql', ['-X', '-q', '-t', '-A', '-v', 'ON_ERROR_STOP=1'],
        { timeout: 30_000, maxBuffer: 64 * 1024 ** 2 }, (error, stdout) => {
          if (error) return reject(new Error('export_unavailable'));
          try { resolve(JSON.parse(stdout)); } catch { reject(new Error('export_unavailable')); }
        });
      child.stdin.on('error', () => {});
      child.stdin.end(`SELECT app.exports_command(convert_from(decode('${encoded}','base64'),'UTF8')::jsonb);`);
    });
  } };
}
