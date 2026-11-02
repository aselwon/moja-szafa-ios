import { postgresExports } from './service.mjs';
// Invoke every minute under the deployment scheduler; safe to retry after restart.
try { await postgresExports().call('sweep', {}); }
catch { process.stderr.write('export_cleanup_unavailable\n'); process.exitCode = 1; }
