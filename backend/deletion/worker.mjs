import { pathToFileURL } from 'node:url';
import { resolve } from 'node:path';
import { setTimeout as sleep } from 'node:timers/promises';
import { postgresDeletionStore } from './postgres.mjs';
import { runDeletionOnce } from './service.mjs';

// Operator-controlled adapter module path; never load a path supplied by a user.
// Credentials belong in the deployment secret store, never CLI arguments/logs.
async function main() {
  if (!process.argv[2]) throw new Error('adapter_required');
  const implementation = await import(pathToFileURL(resolve(process.argv[2])).href);
  const adapters = {};
  for (const name of ['revokeSessions', 'revokeAppleTokens', 'removeImages', 'deleteAuthIdentity']) {
    if (typeof implementation[name] !== 'function') throw new Error('adapter_required');
    adapters[name] = async (...args) => {
      let timer;
      try {
        await Promise.race([
          implementation[name](...args),
          new Promise((_, reject) => { timer = setTimeout(() => reject(new Error('timeout')), 45000); })
        ]);
      } finally { clearTimeout(timer); }
    };
  }
  let stopping = false;
  process.on('SIGTERM', () => { stopping = true; });
  process.on('SIGINT', () => { stopping = true; });
  const store = postgresDeletionStore();
  while (!stopping) {
    try {
      if (!await runDeletionOnce(store, adapters) && !stopping) await sleep(1000);
    } catch {
      process.stderr.write('deletion_worker_unavailable\n');
      if (!stopping) await sleep(1000);
    }
  }
}
main().catch(() => { process.stderr.write('deletion_worker_start_failed\n'); process.exitCode = 1; });
