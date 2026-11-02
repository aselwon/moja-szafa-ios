import { randomBytes } from 'node:crypto';
import { setTimeout as sleep } from 'node:timers/promises';
import { ImagePipeline, privateFiles, postgresImages } from './pipeline.mjs';

// Run under a supervisor with the same private volume and libpq identity as HTTP.
// This process issues no capabilities; its ephemeral key is never used for URLs.
const directory = process.argv[2];
if (!directory) throw new Error('private_volume_required');
const pipeline = new ImagePipeline({ store: postgresImages(), storage: privateFiles(directory), signingKey: randomBytes(32) });
let stopping = false;
process.on('SIGTERM', () => { stopping = true; });
process.on('SIGINT', () => { stopping = true; });
while (!stopping) {
  try {
    const count = await pipeline.sweep();
    if (count < 100 && !stopping) await sleep(10_000);
  } catch {
    process.stderr.write('image_cleanup_unavailable\n');
    if (!stopping) await sleep(10_000);
  }
}
