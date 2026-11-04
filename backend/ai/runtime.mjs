import { execFile } from 'node:child_process';
import { isAbsolute } from 'node:path';
import { privateFiles } from '../images/pipeline.mjs';
import { validateRecognition } from './recognition.mjs';

const uuid = value => typeof value === 'string' && /^[a-f0-9]{8}(-[a-f0-9]{4}){3}-[a-f0-9]{12}$/i.test(value);
const fail = () => { throw new Error('runtime_unavailable'); };
export function runtimeQuery(operation, values) {
  const calls = { input:'app.ai_runtime_input((v->>0)::uuid,(v->>1)::uuid)',
    dispatch:'app.ai_runtime_dispatch((v->>0)::uuid,(v->>1)::uuid,v->>2)',
    telemetry:'app.ai_runtime_telemetry((v->>0)::uuid,(v->>1)::integer,(v->>2)::integer,v->3)' };
  if (!Object.hasOwn(calls,operation)) fail();
  const encoded=Buffer.from(JSON.stringify(values)).toString('base64');
  const sql=`WITH input AS (SELECT convert_from(decode('${encoded}','base64'),'UTF8')::jsonb AS v) SELECT coalesce(to_jsonb(${calls[operation]}),'null'::jsonb) FROM input;`;
  return new Promise((resolve,reject)=>{
    const child=execFile('psql',['-X','-q','-t','-A','-v','ON_ERROR_STOP=1'],{timeout:10000,maxBuffer:2*1024*1024},(error,stdout)=>{
      if(error)return reject(new Error('runtime_storage_unavailable'));
      try {resolve(JSON.parse(stdout));}catch{reject(new Error('runtime_storage_unavailable'));}
    });
    child.stdin.on('error',()=>{});child.stdin.end(sql);
  });
}
export function createRuntime({query=runtimeQuery,storage,validateOutfits}) {
  function identity(job) {
    if(!uuid(job?.id)||!uuid(job?.user_id)||!uuid(job?.lease_token)||!Number.isSafeInteger(job.attempt)||job.attempt<1)fail();
  }
  return {
    async resolveInput(job) {
      identity(job);
      const input=await query('input',[job.id,job.lease_token]);
      if(!input)fail();
      if(job.kind==='image_analysis') {
        if(input.mimeType!=='image/jpeg'||typeof input.object_key!=='string'||!input.object_key.endsWith('/thumbnail.jpg'))fail();
        const bytes=await storage.get(input.object_key);
        if(!Buffer.isBuffer(bytes)||!bytes.length||bytes.length>3*1024*1024)fail();
        return {mimeType:'image/jpeg',base64:bytes.toString('base64')};
      }
      if(job.kind!=='outfit_generation')fail();
      return input;
    },
    async authorizeRecipient(job,recipient) {
      identity(job);
      if(recipient!=='Cloudflare Workers AI')return false;
      return await query('dispatch',[job.id,job.lease_token,recipient])===true;
    },
    async validateResult(job,result,input) {
      identity(job);
      if(job.kind==='image_analysis')return validateRecognition(result);
      if(job.kind!=='outfit_generation'||typeof validateOutfits!=='function')fail();
      return validateOutfits(result,input);
    },
    async recordTelemetry(record) {
      if(!uuid(record?.job_id)||!Number.isSafeInteger(record.attempt)||record.attempt<1)fail();
      const {job_id,attempt,provider_call=1,...telemetry}=record;
      if(![1,2].includes(provider_call))fail();
      if(await query('telemetry',[job_id,attempt,provider_call,telemetry])!==true)fail();
    }
  };
}
let configured;
async function current() {
  if(!configured) {
    if(!isAbsolute(process.env.PRIVATE_IMAGE_DIRECTORY??''))fail();
    configured=createRuntime({storage:privateFiles(process.env.PRIVATE_IMAGE_DIRECTORY),
      validateOutfits:async(result,input)=>{const module=await import('./outfits.mjs');const raw={outfits:result.outfits.map(({garment_ids,rationale})=>({garment_ids,rationale})),shortfall_reason:result.shortfall_reason};return module.validateOutfits(raw,input);}});
  }
  return configured;
}
export const resolveInput=async job=>(await current()).resolveInput(job);
export const authorizeRecipient=async(job,recipient)=>(await current()).authorizeRecipient(job,recipient);
export const validateResult=async(job,result,input)=>(await current()).validateResult(job,result,input);
export const recordTelemetry=async record=>(await current()).recordTelemetry(record);
