import { pathToFileURL } from 'node:url';
import { resolve } from 'node:path';
import { setTimeout as sleep } from 'node:timers/promises';
import { AccountDeletion, postgresDeletion } from './service.mjs';

// Operator-supplied deployment module; never a user-controlled path. Missing
// identity/storage/backup adapters stop startup instead of simulating deletion.
const modulePath = process.argv[2];
if (!modulePath) throw new Error('deletion_runtime_module_required');
const { identity, storage, backups, store = postgresDeletion() } = await import(pathToFileURL(resolve(modulePath)).href);
for (const [adapter, methods] of [[identity, ['revokeAllSessions', 'revokeAppleTokens', 'deleteAccount']],
  [storage, ['eraseAccount']], [backups, ['recordDeletion']]]) {
  for (const method of methods) if (typeof adapter?.[method] !== 'function') throw new Error('deletion_adapter_required');
}
const service = new AccountDeletion({ store, identity, storage, backups });
let stopping = false;
process.on('SIGTERM', () => { stopping = true; });
process.on('SIGINT', () => { stopping = true; });
while (!stopping) {
  try { await service.tick(); }
  catch { process.stderr.write('deletion_worker_unavailable\n'); }
  if (!stopping) await sleep(10_000);
}
