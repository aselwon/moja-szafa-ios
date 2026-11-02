import { postgresImageLedger, privateFiles } from './pipeline.mjs';

// Invoke periodically under the worker service identity, using libpq service
// configuration and an absolute private volume path. No signing key is needed.
try {
  const directory = process.argv[2];
  if (!directory?.startsWith('/')) throw new Error('private_volume_required');
  const ledger = postgresImageLedger();
  const objects = privateFiles(directory);
  const rows = await ledger.call('sweep', {});
  for (const row of rows) {
    await objects.remove(row.original_key);
    await objects.remove(row.thumbnail_key);
    await ledger.call('swept', { id: row.id });
  }
  process.stdout.write(`image_cleanup_processed=${rows.length}\n`);
} catch {
  process.stderr.write('image_cleanup_failed\n');
  process.exitCode = 1;
}
