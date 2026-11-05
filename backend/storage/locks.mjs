import { constants } from 'node:fs';
import { mkdir, open } from 'node:fs/promises';
import { join } from 'node:path';
import { setTimeout as sleep } from 'node:timers/promises';

// Local POSIX filesystem only. Never unlink lock files: replacement would let
// two processes lock different inodes for the same owner. The writing process
// owns the descriptor, so process death releases the lock without stale leases.
export async function lockOwner(directory, owner, { signal, timeoutMs = 240_000 } = {}) {
  if (!/^[a-f0-9]{8}(-[a-f0-9]{4}){3}-[a-f0-9]{12}$/.test(owner)) throw new Error('invalid_storage_owner');
  const { default: { flockSync } } = await import('fs-ext');
  await mkdir(directory, { recursive: true, mode: 0o700 });
  const file = await open(join(directory, owner), constants.O_CREAT | constants.O_RDWR | constants.O_NOFOLLOW, 0o600);
  const deadline = Date.now() + timeoutMs;
  try {
    while (true) {
      signal?.throwIfAborted();
      try { flockSync(file.fd, 'exnb'); break; }
      catch (error) { if (!['EAGAIN','EWOULDBLOCK'].includes(error.code)) throw error; }
      if (Date.now() >= deadline) throw new Error('storage_lock_timeout');
      await sleep(25, undefined, { signal });
    }
    let released = false;
    return async () => {
      if (released) return;
      released = true;
      await file.close();
    };
  } catch (error) { await file.close(); throw error; }
}
