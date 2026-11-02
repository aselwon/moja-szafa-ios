// Synthetic integration drill ONLY. Never accepts an existing database or volume.
// Requires a dedicated local test cluster with PostgreSQL 15 and test admin rights.
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { randomBytes } from 'node:crypto';
import { cp, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { ImagePipeline, privateFiles, postgresImages } from '../images/pipeline.mjs';
import { recoveryMetrics } from './metrics.mjs';

assert.equal(process.argv[2], '--synthetic-local-only', 'Explicit synthetic drill flag required');
assert.ok(['127.0.0.1', 'localhost', '::1'].includes(process.env.PGHOST), 'Local dedicated test cluster required');
for (const tool of ['psql', 'createdb', 'dropdb', 'pg_dump', 'pg_restore']) {
  execFileSync(tool, ['--version'], { stdio: 'pipe' });
}
const backend = fileURLToPath(new URL('../', import.meta.url));
const tag = `wardrobe_t055_${process.pid}_${randomBytes(4).toString('hex')}`;
const source = `${tag}_source`, target = `${tag}_restore`;
const directory = await mkdtemp(resolve(tmpdir(), 'wardrobe-t055-'));
const created = [];
const originalDatabase = process.env.PGDATABASE;
const run = (tool, args, input) => execFileSync(tool, args, { input, encoding: 'utf8', stdio: ['pipe', 'pipe', 'pipe'] });
const sql = (database, input) => run('psql', ['-X', '-qAt', '-v', 'ON_ERROR_STOP=1', '-d', database], input).trim();
const stamp = () => new Date().toISOString();
const id = (group, n) => `${group}0000000-0000-4000-8000-${String(n).padStart(12, '0')}`;
const liveVolume = resolve(directory, 'live');
const backupVolume = resolve(directory, 'backup-images');
const restoredVolume = resolve(directory, 'restored-images');
try {
  for (const database of [source, target]) {
    run('createdb', [database]); created.push(database);
  }
  run('psql', ['-X', '-v', 'ON_ERROR_STOP=1', '-d', source, '-f', resolve(backend, 'tests/bootstrap.sql')]);
  run('bash', [resolve(backend, 'migrate.sh'), source]);
  // Three owners: retained, account deleted after backup, garment deleted after backup.
  const storage = privateFiles(liveVolume);
  for (const n of [1, 2, 3]) {
    sql(source, `INSERT INTO auth.users(id) VALUES ('${id(1,n)}');
      INSERT INTO app.profiles(id,user_id) VALUES ('${id(1,n)}','${id(1,n)}');
      INSERT INTO app.garments(id,user_id,name,category) VALUES ('${id(2,n)}','${id(1,n)}','Synthetic restore fixture','top');
      INSERT INTO api_private.image_uploads(id,user_id,garment_id,state)
        VALUES ('${id(3,n)}','${id(1,n)}','${id(2,n)}','ready');
      INSERT INTO app.garment_images(user_id,garment_id,variant,object_key,status)
        SELECT '${id(1,n)}','${id(2,n)}',v,'${id(3,n)}/' || v || '.jpg','ready'
        FROM unnest(ARRAY['original','thumbnail']) v;`);
    for (const variant of ['original', 'thumbnail']) {
      // Opaque synthetic bytes test copy integrity, not JPEG decoding (T011 tests that).
      await storage.put(`${id(3,n)}/${variant}.jpg`, Buffer.from(`synthetic-${n}-${variant}`));
    }
  }
  // No concurrent writers: both stores represent the same quiesced recovery point.
  const recoveryPoint = stamp();
  const dump = resolve(directory, 'database.dump');
  run('pg_dump', ['--format=custom', '--file', dump, source]);
  await cp(liveVolume, backupVolume, { recursive: true });
  // This ledger is OUTSIDE the old backup; real deployment needs independent durability.
  const ledgerPath = resolve(directory, 'post-backup-deletions.json');
  await writeFile(ledgerPath, JSON.stringify([
    { kind: 'account', owner: id(1,2) }, { kind: 'garment', owner: id(1,3), garment: id(2,3) }
  ]), { mode: 0o600 });
  sql(source, `DELETE FROM auth.users WHERE id = '${id(1,2)}';
    DELETE FROM app.garments WHERE user_id = '${id(1,3)}' AND id = '${id(2,3)}';`);
  const incidentAt = stamp();
  run('pg_restore', ['--exit-on-error', '--single-transaction', '--dbname', target, dump]);
  await cp(backupVolume, restoredVolume, { recursive: true });
  assert.equal(sql(target, 'SELECT count(*) FROM app.garments;'), '3', 'Restore must actually resurrect old rows before replay');
  for (const n of [1,2,3]) for (const variant of ['original', 'thumbnail']) {
    const key = `${id(3,n)}/${variant}.jpg`;
    assert.deepEqual(await readFile(resolve(restoredVolume, key)), await storage.get(key));
  }
  const ledger = JSON.parse(await readFile(ledgerPath, 'utf8'));
  // Fixture-specific statements, never an executor for untrusted production journals.
  assert.deepEqual(ledger, [{ kind: 'account', owner: id(1,2) }, { kind: 'garment', owner: id(1,3), garment: id(2,3) }]);
  process.env.PGDATABASE = target;
  const pipeline = new ImagePipeline({ store: postgresImages(), storage: privateFiles(restoredVolume), signingKey: randomBytes(32) });
  for (let replay = 0; replay < 2; replay++) {
    sql(target, `BEGIN;
      DELETE FROM auth.users WHERE id = '${ledger[0].owner}';
      DELETE FROM app.garments WHERE user_id = '${ledger[1].owner}' AND id = '${ledger[1].garment}';
      UPDATE api_private.image_uploads SET next_cleanup_at = clock_timestamp() WHERE state = 'retired';
      COMMIT;`);
    await pipeline.sweep();
    assert.equal(sql(target, 'SELECT count(*) FROM app.garments;'), '1');
    assert.equal(sql(target, 'SELECT count(*) FROM auth.users;'), '2');
    assert.equal(sql(target, 'SELECT count(*) FROM app.garment_images;'), '2');
    for (const n of [2,3]) {
      await assert.rejects(pipeline.downloadToken(id(1,n), id(3,n)), /image_access_denied/);
      for (const variant of ['original','thumbnail']) {
        await assert.rejects(readFile(resolve(restoredVolume, `${id(3,n)}/${variant}.jpg`)), { code: 'ENOENT' });
      }
    }
    const token = await pipeline.downloadToken(id(1,1), id(3,1));
    assert.deepEqual((await pipeline.download(id(1,1), token)).bytes, await storage.get(`${id(3,1)}/thumbnail.jpg`));
    await assert.rejects(pipeline.download(id(1,3), token), /image_access_denied/);
    // Reintroduce deleted bytes as a second storage restore; tombstones must clean again.
    if (replay === 0) await cp(backupVolume, restoredVolume, { recursive: true });
  }
  const verifiedAt = stamp();
  const metrics = recoveryMetrics({ incidentAt, databasePoint: recoveryPoint, imagesPoint: recoveryPoint,
    verifiedAt, deletionsVerified: true });
  assert.equal(metrics.passed, true);
  console.log(JSON.stringify({ scope: 'synthetic local integration only; not production RPO/RTO evidence',
    recoveryPoint, incidentAt, verifiedAt, ...metrics }));
} finally {
  if (originalDatabase === undefined) delete process.env.PGDATABASE;
  else process.env.PGDATABASE = originalDatabase;
  try {
    for (const database of created.reverse()) run('dropdb', ['--if-exists', database]);
  } finally { await rm(directory, { recursive: true, force: true }); }
}
