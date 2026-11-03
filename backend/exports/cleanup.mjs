import { setTimeout as sleep } from 'node:timers/promises';
import { DataExports, postgresExports } from './service.mjs';

// Run under a supervisor, with the same dedicated private spool as HTTP.
const directory = process.argv[2];
if (!directory) throw new Error('export_spool_required');
const exports = new DataExports({ store: postgresExports(), directory });
let stopping = false;
process.on('SIGTERM', () => { stopping = true; });
process.on('SIGINT', () => { stopping = true; });
while (!stopping) {
  try { await exports.sweep(); }
  catch { process.stderr.write('export_cleanup_unavailable\n'); }
  if (!stopping) await sleep(10_000);
}
