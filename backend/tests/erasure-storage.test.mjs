import assert from 'node:assert/strict';
import { mkdtemp, mkdir, writeFile, access, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { lockOwner } from '../storage/locks.mjs';
import { ImagePipeline, privateFiles } from '../images/pipeline.mjs';
import { privateAccountStorage } from '../deletion/adapters/private-storage.mjs';

const owner = '11111111-1111-4111-8111-111111111111';
const other = '22222222-2222-4222-8222-222222222222';
const id = '33333333-3333-4333-8333-333333333333';
const root = await mkdtemp(join(tmpdir(), 'szafa-erasure-storage-'));
try {
  const directory = join(root, 'locks');
  const moduleURL = new URL('../storage/locks.mjs', import.meta.url).href;
  const child = spawn(process.execPath, ['--input-type=module', '-e',
    `import {lockOwner} from ${JSON.stringify(moduleURL)}; await lockOwner(${JSON.stringify(directory)},${JSON.stringify(owner)}); process.send('locked'); setInterval(()=>{},1000);`],
  { stdio: ['ignore', 'ignore', 'pipe', 'ipc'] });
  try {
    await once(child, 'message', { signal: AbortSignal.timeout(5000) });
    await assert.rejects(lockOwner(directory, owner, { timeoutMs: 30 }), /storage_lock_timeout/);
    const exited = once(child, 'exit');
    child.kill('SIGKILL'); await exited;
    const release = await lockOwner(directory, owner, { timeoutMs: 1000 });
    await release();
  } finally { child.kill('SIGKILL'); }

  const images = privateFiles(join(root, 'images'));
  const exportDirectory = join(root, 'exports');
  await mkdir(join(exportDirectory, `export-${owner}-ABC123`), { recursive: true });
  await mkdir(join(exportDirectory, `export-${other}-DEF456`));
  await writeFile(join(exportDirectory, `export-${owner}-ABC123`, 'moja-szafa.tar'), 'private');
  let decoded, continueDecode;
  const decoding = new Promise(resolve => { decoded = resolve; });
  const barrier = new Promise(resolve => { continueDecode = resolve; });
  let tombstoned = false;
  const pipeline = new ImagePipeline({ signingKey: Buffer.alloc(32, 7), storage: images,
    store: { async call(action) { return tombstoned ? null : action === 'claim' ? { state: 'uploading', fence: id, has_cleaned: true } : true; } },
    async decode() { decoded(); await barrier; return { original: { data: 'YQ==' }, thumbnail: { data: 'Yg==' }, cleaned: { data: 'Yw==' } }; }
  });
  const pair = Buffer.concat([Buffer.from([0,0,0,9]), Buffer.from('synthetic'), Buffer.from('cleaned')]);
  const upload = pipeline.upload(owner, pipeline.sign(owner, id, 'upload'), pair, true);
  await decoding;
  tombstoned = true;
  const storage = privateAccountStorage({ images, exportDirectory,
    store: { assertLease: async () => true, imageIDs: async () => [id] } });
  const erasure = storage.eraseAccount(owner, { job: id, fence: id, signal: new AbortController().signal });
  continueDecode();
  await assert.rejects(upload, /image_access_denied/);
  await erasure;
  await assert.rejects(images.get(`${id}/original.jpg`), { code: 'ENOENT' });
  await assert.rejects(images.get(`${id}/thumbnail.jpg`), { code: 'ENOENT' });
  await assert.rejects(images.get(`${id}/cleaned.png`), { code: 'ENOENT' });
  await assert.rejects(access(join(exportDirectory, `export-${owner}-ABC123`)), { code: 'ENOENT' });
  await access(join(exportDirectory, `export-${other}-DEF456`));
  await assert.rejects(pipeline.upload(owner, pipeline.sign(owner, id, 'upload'), Buffer.from('retry')), /image_access_denied/);
} finally { await rm(root, { recursive: true, force: true }); }
console.log('OK: process death releases storage fence; deletion drains late writers and preserves other owners');
