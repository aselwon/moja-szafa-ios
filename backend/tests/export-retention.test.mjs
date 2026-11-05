import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, writeFile, utimes, readdir, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { setTimeout as sleep } from 'node:timers/promises';
import { startExportRetention } from '../gateway/export-retention.mjs';

test('gateway startup removes expired export spools but preserves fresh files and unrelated paths', async t => {
  const directory = await mkdtemp(join(tmpdir(),'szafa-retention-'));
  t.after(()=>rm(directory,{recursive:true,force:true}));
  for (const name of ['export-expired','export-active','unrelated']) {
    const path=join(directory,name); await mkdir(path); await writeFile(join(path,'archive.tar'),'synthetic');
    if(name!=='export-active') await utimes(path,new Date(0),new Date(0));
  }
  let calls=0;
  const retention=startExportRetention({directory,store:{async pruneExports(){calls++;}}});
  t.after(()=>retention.stop());
  await retention.ready;
  assert.equal(calls,1);
  assert.deepEqual((await readdir(directory)).sort(),['export-active','unrelated']);
});

test('retention retries a failed sweep, never overlaps slow work, and drains on shutdown', {timeout:3000}, async t => {
  const directory=await mkdtemp(join(tmpdir(),'szafa-retention-'));
  t.after(()=>rm(directory,{recursive:true,force:true}));
  let calls=0, errors=0, release, started;
  const secondStarted=new Promise(resolve=>{started=resolve;});
  const blocked=new Promise(resolve=>{release=resolve;});
  const retention=startExportRetention({directory,intervalMs:10,onError:()=>errors++,store:{async pruneExports(){
    calls++; if(calls===1)throw new Error('synthetic'); started(); await blocked;
  }}});
  t.after(async()=>{release();await retention.stop();});
  await retention.ready;
  // Keep the event loop alive while the production timer is deliberately unref'd.
  await Promise.race([secondStarted,sleep(1000).then(()=>{throw new Error('retry missing');})]);
  await sleep(35); assert.equal(calls,2); assert.equal(errors,1);
  let stopped=false; const stop=retention.stop().then(()=>{stopped=true;});
  await sleep(15); assert.equal(stopped,false);
  release(); await stop; await sleep(35); assert.equal(calls,2);
});
