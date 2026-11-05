import { execFile } from 'node:child_process';
import { pathToFileURL } from 'node:url';
import { acknowledgement, deletionBytes, deletionHash, readJournalFile, writeJournalFile, uuid } from './adapters/journal-records.mjs';

export async function replicateJournal({ directory, replica, list, acknowledge }) {
  if (!uuid(replica)) throw new Error('invalid_journal_replica');
  const { records } = await list();
  if (!Array.isArray(records) || records.length>500) throw new Error('invalid_journal_batch');
  let copied=0;
  for (const record of records) {
    const bytes=deletionBytes(record);
    await writeJournalFile(directory,record.job,bytes);
    const persisted=await readJournalFile(directory,record.job);
    if(persisted!==bytes || deletionHash(JSON.parse(persisted))!==deletionHash(record))throw new Error('journal_replica_conflict');
    const result=await acknowledge(JSON.parse(acknowledgement(record,replica)));
    if(result?.acknowledged!==true)throw new Error('journal_acknowledgement_unavailable');
    copied++;
  }
  return { copied };
}

export function sshJournal({ host, port, receiver, remoteDirectory, remoteAcknowledgements, replica }) {
  if (!/^[a-z_][a-z0-9_-]*@[a-z0-9.-]+$/.test(host) || !/^\d{1,5}$/.test(String(port)) || Number(port)<1 || Number(port)>65535 ||
      ![receiver,remoteDirectory,remoteAcknowledgements].every(path=>/^\/[a-zA-Z0-9_./-]+$/.test(path)) || !uuid(replica))throw new Error('invalid_replication_configuration');
  function command(action,body) {
    return new Promise((resolve,reject)=>{
      const remote=['node',receiver,remoteDirectory,remoteAcknowledgements,replica,action].join(' ');
      const child=execFile('/usr/bin/ssh',['-F','/dev/null','-o','BatchMode=yes','-o','ConnectTimeout=10','-p',String(port),host,remote],
        {timeout:30000,maxBuffer:1024*1024},(error,stdout)=>{
          if(error)return reject(new Error('journal_transport_unavailable'));
          try{resolve(JSON.parse(stdout));}catch{reject(new Error('invalid_journal_response'));}
        });
      child.stdin.on('error',()=>{}); child.stdin.end(body?JSON.stringify(body):'');
    });
  }
  return {list:()=>command('list'),acknowledge:body=>command('ack',body)};
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    const [directory,replica,host,port,receiver,remoteDirectory,remoteAcknowledgements]=process.argv.slice(2);
    const result=await replicateJournal({directory,replica,...sshJournal({host,port,receiver,remoteDirectory,remoteAcknowledgements,replica})});
    if(result.copied)process.stdout.write(`journal_records_replicated=${result.copied}\n`);
  } catch { process.stderr.write('journal_replication_failed\n'); process.exitCode=1; }
}
