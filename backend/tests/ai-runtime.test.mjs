import test from 'node:test';
import assert from 'node:assert/strict';
import {createRuntime} from '../ai/runtime.mjs';
import {cloudflareEnvironment} from '../ai/cloudflare-adapter.mjs';
import {serverConfiguration} from '../ai/provider.mjs';
import {ADAPTER_TIMEOUT_MS} from '../worker/worker.mjs';
const job={id:'00000000-0000-0000-0000-000000000001',user_id:'00000000-0000-0000-0000-000000000002',lease_token:'00000000-0000-0000-0000-000000000003',attempt:1,kind:'image_analysis',input:{object_key:'attacker'}};
test('runtime resolves only database-owned normalized thumbnail and persists immutable bounded call telemetry',async()=>{
 const calls=[];const runtime=createRuntime({query:async(op,args)=>{calls.push([op,args]);return op==='input'?{object_key:'trusted/thumbnail.jpg',mimeType:'image/jpeg'}:true;},storage:{get:async key=>{assert.equal(key,'trusted/thumbnail.jpg');return Buffer.from('synthetic-normalized');}}});
 assert.equal((await runtime.resolveInput(job)).base64,Buffer.from('synthetic-normalized').toString('base64'));
 assert.deepEqual(calls[0],['input',[job.id,job.lease_token]]);
 assert.equal(await runtime.authorizeRecipient(job,'Other provider'),false);
 assert.equal(await runtime.authorizeRecipient(job,'Cloudflare Workers AI'),true);
 await runtime.recordTelemetry({job_id:job.id,attempt:1,provider_call:2,status:'success'});
 assert.deepEqual(calls.at(-1),['telemetry',[job.id,1,2,{status:'success'}]]);
 await assert.rejects(()=>runtime.recordTelemetry({job_id:job.id,attempt:1,provider_call:3}));
 const unavailable=createRuntime({query:async()=>null,storage:{get:()=>{throw Error('must not read');}}});
 await assert.rejects(()=>unavailable.resolveInput(job));
});
test('Cloudflare configuration fixes endpoint and free model allowlist; unsafe or paid setup fails closed',async()=>{
 const env={CLOUDFLARE_WORKERS_PLAN:'free',CLOUDFLARE_ACCOUNT_ID:'a'.repeat(32),CLOUDFLARE_AI_TOKEN_FILE:'/private/synthetic-token',AI_ENDPOINT:'https://attacker.invalid',AI_IMAGE_MODEL:'paid-model'};
 const io={metadata:async()=>({isFile:()=>true,mode:0o100600,size:40}),read:async()=>'synthetic_cloudflare_token_value'};
 const configured=await cloudflareEnvironment(env,io);const config=serverConfiguration(configured);
 assert.equal(config.endpoint,`https://api.cloudflare.com/client/v4/accounts/${'a'.repeat(32)}/ai/v1/chat/completions`);
 assert.equal(config.imageModel,'@cf/google/gemma-4-26b-a4b-it');assert.equal(config.maxOutputTokens,1024);
 assert.equal(config.outfitModel,'@cf/meta/llama-3.3-70b-instruct-fp8-fast');
 assert.equal(config.timeoutMs,30000); // Single image call keeps its existing budget.
 assert(config.outfitTimeoutMs*2+10000<ADAPTER_TIMEOUT_MS); // Leave time for scoped database operations.
 for(const value of ['0','35001','not-a-number'])assert.throws(()=>serverConfiguration({...configured,AI_OUTFIT_TIMEOUT_MS:value}),/configuration_invalid/);
 for(const bad of [{CLOUDFLARE_WORKERS_PLAN:'paid'},{CLOUDFLARE_ACCOUNT_ID:'../escape'},{CLOUDFLARE_AI_TOKEN_FILE:'relative'}])await assert.rejects(()=>cloudflareEnvironment({...env,...bad},io));
 await assert.rejects(()=>cloudflareEnvironment(env,{...io,metadata:async()=>({isFile:()=>true,mode:0o100644,size:40})}));
 await assert.rejects(()=>cloudflareEnvironment(env,{...io,read:async()=> 'token\r\ninjection'}));
});

test('AI contracts reference real SQL RPCs',async()=>{
 const {readFile}=await import('node:fs/promises');
 const contract=JSON.parse(await readFile(new URL('../api/openapi-ai-v1.json',import.meta.url),'utf8'));
 const sql=(await Promise.all(['016_ai_runtime_guardrails.sql','032_recognition_drafts.sql'].map(file=>readFile(new URL('../migrations/'+file,import.meta.url),'utf8')))).join('\n');
 assert.deepEqual(Object.keys(contract.paths).sort(),['/rest/v1/rpc/api_v1_generate_outfits','/rest/v1/rpc/api_v1_job_result','/rest/v1/rpc/api_v1_recognition']);
 for(const [path,route] of Object.entries(contract.paths)) {
   assert.equal(path,'/rest/v1/rpc/'+route.post.operationId);
   assert(sql.includes(`CREATE FUNCTION app.${route.post.operationId}(request jsonb)`));
   assert.equal(route.post.requestBody.content['application/json'].schema.additionalProperties,false);
   assert.equal(route.post.responses['200'].content['application/json'].schema.oneOf.length,2);
 }
});
