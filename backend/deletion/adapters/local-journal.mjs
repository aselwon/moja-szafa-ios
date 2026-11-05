import { resolve } from 'node:path';
import { uuid, deletionBytes, writeJournalFile } from './journal-records.mjs';

// Durable local retry journal, NOT immutable or independently retained.
export function localDeletionJournal({ directory, assertLease }) {
  if (!directory || resolve(directory) !== directory || typeof assertLease !== 'function') throw new Error('journal_configuration_required');
  return {
    async recordDeletion(owner, job, options) {
      if (!uuid(owner) || !uuid(job) || options?.job !== job || !uuid(options?.fence) || !options.signal) throw new Error('invalid_deletion_context');
      options.signal.throwIfAborted();
      if (!await assertLease(owner, options)) throw new Error('lease_lost');
      await writeJournalFile(directory, job, deletionBytes({ version: 1, owner, job }));
      options.signal.throwIfAborted();
    }
  };
}
