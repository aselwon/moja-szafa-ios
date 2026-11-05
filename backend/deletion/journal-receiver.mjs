import { readdir } from 'node:fs/promises';
import { pathToFileURL } from 'node:url';
import { acknowledgement, deletionBytes, readJournalFile, writeJournalFile, uuid } from './adapters/journal-records.mjs';

// SSH-only operator command. No HTTP listener and no user-controlled file paths.
export async function journalReceiver({ directory, acknowledgementDirectory, replica }, action, input) {
  if (!uuid(replica)) throw new Error('invalid_journal_replica');
  if (action === 'list') {
    const records = [];
    for (const name of (await readdir(directory)).sort()) {
      if (!name.endsWith('.json') || !uuid(name.slice(0,-5))) continue;
      const bytes = await readJournalFile(directory, name.slice(0,-5));
      const record = JSON.parse(bytes);
      if (deletionBytes(record) !== bytes || `${record.job}.json` !== name) throw new Error('invalid_journal_record');
      try {
        if (await readJournalFile(acknowledgementDirectory, record.job) !== acknowledgement(record,replica)) throw new Error('journal_replica_conflict');
      } catch (error) {
        if (error.code !== 'ENOENT') throw error;
        records.push(record);
      }
      if (records.length >= 500) break;
    }
    return { records };
  }
  if (action === 'ack') {
    if (!input || !uuid(input.job)) throw new Error('invalid_journal_record');
    const record = JSON.parse(await readJournalFile(directory,input.job));
    const expected = acknowledgement(record,replica);
    if (JSON.stringify(input)+'\n' !== expected) throw new Error('journal_replica_conflict');
    await writeJournalFile(acknowledgementDirectory,record.job,expected);
    return { acknowledged: true };
  }
  throw new Error('invalid_journal_action');
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    const [directory,acknowledgementDirectory,replica,action] = process.argv.slice(2);
    let body=''; for await (const chunk of process.stdin) { body+=chunk; if(Buffer.byteLength(body)>4096)throw new Error('invalid_journal_record'); }
    const result=await journalReceiver({directory,acknowledgementDirectory,replica},action,body?JSON.parse(body):undefined);
    process.stdout.write(JSON.stringify(result)+'\n');
  } catch { process.stderr.write('journal_receiver_failed\n'); process.exitCode=1; }
}
