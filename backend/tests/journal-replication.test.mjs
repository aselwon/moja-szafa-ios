import assert from 'node:assert/strict';
import { mkdtemp,mkdir,rm } from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { randomUUID } from 'node:crypto';
import { localDeletionJournal } from '../deletion/adapters/local-journal.mjs';
import { replicatedDeletionJournal } from '../deletion/adapters/replicated-journal.mjs';
import { deletionBytes,acknowledgement,readJournalFile,writeJournalFile } from '../deletion/adapters/journal-records.mjs';
import { journalReceiver } from '../deletion/journal-receiver.mjs';
import { replicateJournal } from '../deletion/journal-replicator.mjs';
import { AccountDeletion } from '../deletion/service.mjs';

const root=await mkdtemp(join(tmpdir(),'szafa-replication-'));
try {
  const directory=join(root,'outbox'), acknowledgementDirectory=join(root,'acks'), destination=join(root,'independent');
  for(const path of [directory,acknowledgementDirectory,destination])await mkdir(path,{mode:0o700});
  const replica=randomUUID(),owner=randomUUID(),job=randomUUID();
  const options={job,fence:randomUUID(),signal:new AbortController().signal};
  const record={version:1,owner,job};
  const config={directory,acknowledgementDirectory,replica};
  const journal=replicatedDeletionJournal({...config,assertLease:async()=>true,waitMs:10,pollMs:2});
  let destructive=0;
  const queue=[];
  const service=new AccountDeletion({store:{async deferReplica(){queue.push('deferReplica');},async call(action){queue.push(action);return action==='claim'?{id:job,owner,fence:options.fence}:true;}},
    backups:journal,identity:{revokeAllSessions:async()=>destructive++,revokeAppleTokens:async()=>destructive++,deleteAccount:async()=>destructive++},storage:{eraseAccount:async()=>destructive++}});
  await service.tick();
  assert.equal(destructive,0,'offline replica keeps cleanup queued without any destructive side effect');
  assert.deepEqual(queue,['claim','deferReplica']);
  const list=()=>journalReceiver(config,'list');
  await assert.rejects(replicateJournal({directory:destination,replica,list,acknowledge:async()=>{throw new Error('lost connection before ack');}}),/lost connection/);
  assert.equal(await readJournalFile(destination,job),deletionBytes(record),'durable independent copy survives lost acknowledgement');
  await assert.rejects(readJournalFile(acknowledgementDirectory,job),{code:'ENOENT'});
  const acknowledge=input=>journalReceiver(config,'ack',input);
  await assert.rejects(acknowledge({...JSON.parse(acknowledgement(record,replica)),sha256:'0'.repeat(64)}),/journal_replica_conflict/);
  await assert.rejects(acknowledge(JSON.parse(acknowledgement(record,randomUUID()))),/journal_replica_conflict/);
  assert.deepEqual(await replicateJournal({directory:destination,replica,list,acknowledge}),{copied:1});
  await journal.recordDeletion(owner,job,options);
  assert.deepEqual(await list(),{records:[]});
  await assert.rejects(journal.recordDeletion(randomUUID(),job,options),/journal_conflict/);
  // An acknowledgement for the same UUID but another payload cannot authorize it.
  const second={version:1,owner,job:randomUUID()};
  await localDeletionJournal({directory,assertLease:async()=>true}).recordDeletion(owner,second.job,{...options,job:second.job});
  await writeJournalFile(acknowledgementDirectory,second.job,acknowledgement({...second,owner:randomUUID()},replica));
  await assert.rejects(journal.recordDeletion(owner,second.job,{...options,job:second.job}),/journal_replica_conflict/);
} finally {await rm(root,{recursive:true,force:true});}
console.log('OK: independent durable copy, lost-ack replay, exact payload binding and offline fail-closed queue');
