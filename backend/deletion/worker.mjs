import { execFile } from 'node:child_process';
import { pathToFileURL } from 'node:url';
import { resolve } from 'node:path';
import { access, constants } from 'node:fs/promises';
import { setTimeout as sleep } from 'node:timers/promises';
import { privateFiles } from '../images/pipeline.mjs';
import { processExecutor } from '../worker/worker.mjs';

export function postgresDeletionStore() {
  return { command: request => new Promise((resolve, reject) => {
    const encoded = Buffer.from(JSON.stringify(request)).toString('base64');
    const sql = `SELECT app.deletion_command(convert_from(decode('${encoded}','base64'),'UTF8')::jsonb);`;
    const child = execFile('psql', ['-X', '-q', '-t', '-A', '-v', 'ON_ERROR_STOP=1'],
      { timeout: 10_000, maxBuffer: 1024 * 1024 }, (error, stdout) => {
        if (error) return reject(new Error('deletion_storage_unavailable'));
        try { resolve(JSON.parse(stdout)); } catch { reject(new Error('deletion_invalid_response')); }
      });
    child.stdin.on('error', () => {});
    child.stdin.end(sql);
  }) };
}

// Authentication adapters are mandatory and must implement idempotent effects.
// One step per lease: process death or a lost response replays that SAME step.
export async function runDeletionOnce(store, execute) {
  const job = await store.command({ action: 'claim' });
  if (!job) return false;
  const fence = { id: job.id, token: job.lease_token, stage: job.stage };
  if (job.stage !== 'purge') {
    let response;
    try { response = await execute(job); } catch { response = null; }
    if (response?.outcome !== 'success') {
      await store.command({ ...fence, action: 'retry' });
      return true;
    }
  }
  // Do not turn an ambiguous database commit into a second provider operation.
  await store.command({ ...fence, action: 'advance' });
  return true;
}

export function deletionExecutor(store, storage, identityExecutor) {
  return async job => {
    if (job.stage !== 'images') return identityExecutor(job);
    const ids = await store.command({ action: 'images', id: job.id, token: job.lease_token });
    if (!Array.isArray(ids)) throw new Error('lease_lost');
    for (const id of ids) {
      await storage.remove(`${id}/original.jpg`);
      await storage.remove(`${id}/thumbnail.jpg`);
    }
    return { outcome: 'success' };
  };
}

async function main() {
  const adapter = process.argv[2];
  if (!adapter || !process.argv[3]) throw new Error('deletion_adapter_and_private_volume_required');
  await access(resolve(adapter), constants.X_OK);
  const store = postgresDeletionStore();
  const execute = deletionExecutor(store, privateFiles(process.argv[3]), processExecutor(adapter, 45_000));
  let stopping = false;
  process.on('SIGTERM', () => { stopping = true; });
  process.on('SIGINT', () => { stopping = true; });
  while (!stopping) {
    try {
      if (!await runDeletionOnce(store, execute) && !stopping) await sleep(1000);
    } catch {
      process.stderr.write('deletion_worker_unavailable\n');
      if (!stopping) await sleep(1000);
    }
  }
}
if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  main().catch(() => { process.stderr.write('deletion_start_failed\n'); process.exitCode = 1; });
}
