import test from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { mkdtemp, mkdir, writeFile, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { setTimeout as sleep } from 'node:timers/promises';
import { startImageRetention } from '../gateway/image-retention.mjs';

test('image retention retries disk failures without acknowledging missing cleanup and preserves unselected images', {timeout:3000}, async t => {
  const directory=await mkdtemp(join(tmpdir(),'szafa-image-retention-'));
  t.after(()=>rm(directory,{recursive:true,force:true}));
  const retired=randomUUID(), active=randomUUID();
  for(const id of [retired,active]) {
    await mkdir(join(directory,id));
    for(const file of ['thumbnail.jpg','cleaned.png']) await writeFile(join(directory,id,file),'synthetic');
  }
  const obstacle=join(directory,retired,'original.jpg');
  await mkdir(obstacle); // A real filesystem error, not a mocked removal result.
  let acknowledged=0,errors=0;
  const retention=startImageRetention({directory,intervalMs:20,onError:()=>errors++,store:{
    async retiredImages(){return acknowledged?[]:[{id:retired}];},
    async acknowledgeRetiredImage(id){assert.equal(id,retired);acknowledged++;}
  }});
  t.after(()=>retention.stop());
  await retention.ready;
  assert.equal(errors,1); assert.equal(acknowledged,0);
  await rm(obstacle,{recursive:true});
  for(let i=0;i<50&&!acknowledged;i++)await sleep(20);
  await retention.stop();
  assert.equal(acknowledged,1);
  for(const file of ['thumbnail.jpg','cleaned.png']) {
    await assert.rejects(readFile(join(directory,retired,file)),error=>error.code==='ENOENT');
    assert.equal(await readFile(join(directory,active,file),'utf8'),'synthetic');
  }
});
