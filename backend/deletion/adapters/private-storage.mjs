import { readdir, rm, open } from 'node:fs/promises';
import { join } from 'node:path';

export function privateAccountStorage({ images, exportDirectory, store }) {
  if (typeof images?.lockOwner !== 'function' || typeof store?.imageIDs !== 'function' || typeof store?.assertLease !== 'function') throw new Error('fenced_storage_required');
  return {
    async eraseAccount(owner, options) {
      const release = await images.lockOwner(owner, options);
      try {
        options.signal.throwIfAborted();
        if (!await store.assertLease(owner, options)) throw new Error('lease_lost');
        // The deletion tombstone already rejects new claims. The owner lock
        // drains all earlier writers and archive streams before erasing bytes.
        const ids = await store.imageIDs(owner, options);
        if (!Array.isArray(ids) || !ids.every(id => /^[a-f0-9]{8}(-[a-f0-9]{4}){3}-[a-f0-9]{12}$/.test(id))) throw new Error('invalid_image_inventory');
        for (const id of ids) {
          options.signal.throwIfAborted();
          for (const name of ['original.jpg', 'thumbnail.jpg', 'cleaned.png']) await images.remove(`${id}/${name}`);
        }
        let names;
        try { names = await readdir(exportDirectory); }
        catch (error) { if (error.code !== 'ENOENT') throw error; names = []; }
        // Old releases did not label spools by owner. Drain/sweep those before
        // activation; guessing their owner would falsely attest full erasure.
        if (names.some(name => /^export-[a-zA-Z0-9]+$/.test(name))) throw new Error('legacy_export_spools_require_cleanup');
        for (const name of names) {
          if (name.startsWith(`export-${owner}-`) && /^[a-zA-Z0-9]+$/.test(name.slice(44))) {
            options.signal.throwIfAborted();
            await rm(join(exportDirectory, name), { recursive: true, force: true });
          }
        }
        if (names.length) {
          const directory = await open(exportDirectory, 'r');
          try { await directory.sync(); } finally { await directory.close(); }
        }
        if (!await store.assertLease(owner, options)) throw new Error('lease_lost');
      } finally { await release(); }
    }
  };
}
