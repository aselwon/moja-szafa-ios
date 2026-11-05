import { setTimeout as sleep } from 'node:timers/promises';
import { localDeletionJournal } from './local-journal.mjs';
import { acknowledgement, readJournalFile, uuid } from './journal-records.mjs';

export function replicatedDeletionJournal({ directory, acknowledgementDirectory, replica, assertLease, waitMs = 90_000, pollMs = 500 }) {
  if (!uuid(replica) || !Number.isInteger(waitMs) || waitMs < 1 || waitMs > 120_000 || !Number.isInteger(pollMs) || pollMs < 1) throw new Error('journal_configuration_required');
  const local = localDeletionJournal({ directory, assertLease });
  return {
    async recordDeletion(owner, job, options) {
      await local.recordDeletion(owner, job, options);
      const expected = acknowledgement({ version: 1, owner, job }, replica);
      const deadline = Date.now() + waitMs;
      while (true) {
        options.signal.throwIfAborted();
        try {
          const received = await readJournalFile(acknowledgementDirectory, job);
          if (received !== expected) throw new Error('journal_replica_conflict');
          if (!await assertLease(owner, options)) throw new Error('lease_lost');
          return;
        } catch (error) { if (error.code !== 'ENOENT') throw error; }
        if (Date.now() >= deadline) throw new Error('journal_replica_unavailable');
        await sleep(Math.min(pollMs, Math.max(1, deadline - Date.now())), undefined, { signal: options.signal });
      }
    }
  };
}
