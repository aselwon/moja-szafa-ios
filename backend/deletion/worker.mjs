import { pathToFileURL } from 'node:url';
import { resolve } from 'node:path';
import { setTimeout as sleep } from 'node:timers/promises';
import { postgresDeletionStore } from './postgres.mjs';
import { runDeletionOnce } from './service.mjs';

// Explicit operator-installed module exporting identity and storage adapters.
// Startup fails without it. No placeholder provider can acknowledge deletion.
const adapterPath = process.argv[2];
if (!adapterPath) throw new Error('deletion_adapter_required');
const { identity, storage } = await import(pathToFileURL(resolve(adapterPath)).href);
for (const method of ['revokeSessions', 'revokeApple', 'deleteUser']) {
  if (typeof identity?.[method] !== 'function') throw new Error('invalid_identity_adapter');
}
if (typeof storage?.remove !== 'function') throw new Error('invalid_storage_adapter');
const store = postgresDeletionStore();
let stopping = false;
process.on('SIGTERM', () => { stopping = true; });
process.on('SIGINT', () => { stopping = true; });
while (!stopping) {
  try { await runDeletionOnce({ store, identity, storage }); }
  catch { process.stderr.write('deletion_attempt_incomplete\n'); }
  if (!stopping) await sleep(1000);
}
