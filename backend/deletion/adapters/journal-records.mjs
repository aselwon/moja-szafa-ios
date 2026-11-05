import { constants } from 'node:fs';
import { open, link, unlink } from 'node:fs/promises';
import { join, resolve } from 'node:path';
import { randomUUID, createHash } from 'node:crypto';

export const uuid = value => typeof value === 'string' && /^[a-f0-9]{8}(-[a-f0-9]{4}){3}-[a-f0-9]{12}$/.test(value);
export function deletionBytes(record) {
  if (!record || Object.keys(record).sort().join(',') !== 'job,owner,version' || record.version !== 1 || !uuid(record.owner) || !uuid(record.job)) throw new Error('invalid_journal_record');
  return JSON.stringify({ version: 1, owner: record.owner, job: record.job }) + '\n';
}
export const deletionHash = record => createHash('sha256').update(deletionBytes(record)).digest('hex');
export const acknowledgement = (record, replica) => {
  if (!uuid(replica)) throw new Error('invalid_journal_replica');
  return JSON.stringify({ version: 1, job: record.job, sha256: deletionHash(record), replica }) + '\n';
};
async function syncDirectory(directory) {
  const handle = await open(directory, constants.O_RDONLY | constants.O_DIRECTORY | constants.O_NOFOLLOW);
  try {
    if (((await handle.stat()).mode & 0o077) !== 0) throw new Error('journal_permissions');
    await handle.sync();
  } finally { await handle.close(); }
}
export async function readJournalFile(directory, id) {
  if (!uuid(id)) throw new Error('invalid_journal_record');
  const file = await open(join(directory, `${id}.json`), constants.O_RDONLY | constants.O_NOFOLLOW);
  try {
    const stat = await file.stat();
    if (!stat.isFile() || stat.size > 4096 || (stat.mode & 0o077) !== 0) throw new Error('journal_permissions');
    return await file.readFile('utf8');
  } finally { await file.close(); }
}
export async function writeJournalFile(directory, id, bytes) {
  if (!directory || resolve(directory) !== directory || !uuid(id) || typeof bytes !== 'string' || Buffer.byteLength(bytes) > 4096) throw new Error('invalid_journal_record');
  await syncDirectory(directory);
  const temporary = join(directory, `.${randomUUID()}.tmp`);
  try {
    const file = await open(temporary, 'wx', 0o600);
    try { await file.writeFile(bytes); await file.sync(); } finally { await file.close(); }
    try { await link(temporary, join(directory, `${id}.json`)); }
    catch (error) {
      if (error.code !== 'EEXIST') throw error;
      if (await readJournalFile(directory, id) !== bytes) throw new Error('journal_conflict');
      const previous = await open(join(directory, `${id}.json`), constants.O_RDONLY | constants.O_NOFOLLOW);
      try { await previous.sync(); } finally { await previous.close(); }
    }
    await syncDirectory(directory);
  } finally { await unlink(temporary).catch(error => { if (error.code !== 'ENOENT') throw error; }); }
  await syncDirectory(directory);
}
