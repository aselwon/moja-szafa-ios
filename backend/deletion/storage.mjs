import { rm } from 'node:fs/promises';
import { resolve } from 'node:path';

// Matches the T011 private-volume layout; includes any interrupted staging files.
// Repeated removals are safe. The existing sweeper handles delayed image writers.
export function privateDeletionStorage(directory) {
  if (!directory) throw new Error('private_volume_required');
  const root = resolve(directory);
  return {
    async remove(uploadID) {
      if (typeof uploadID !== 'string' || !/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i.test(uploadID)) {
        throw new Error('invalid_upload_id');
      }
      await rm(resolve(root, uploadID), { recursive: true, force: true });
    }
  };
}
