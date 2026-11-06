import assert from 'node:assert/strict';
import {workerPreflight} from '../deploy/ai-worker-preflight.mjs';
const env={PGHOST:'ep-synthetic.neon.tech',PGSSLMODE:'verify-full',PGSSLROOTCERT:'/synthetic/ca.pem',PGUSER:'synthetic',PGPASSWORD:'synthetic',PGDATABASE:'synthetic',PRIVATE_IMAGE_DIRECTORY:'/synthetic/private',AI_RUNTIME_ENABLED:'true',AI_WORKER_OUTFIT_ONLY:'true'};
const policy={enabled:false,image_enabled:false,unsupported_jobs_pending:false,recipient:'Cloudflare Workers AI',daily_user_units:4,daily_global_units:10,disclosure_matches:false};
let calls=0;
const dependencies={provider:async()=>{calls++;},checkCA:async()=>{},query:async()=>({role_allowed:true,policy}),requireEnabled:false};
assert.equal((await workerPreflight(env,dependencies)).enabled,false);
await assert.rejects(workerPreflight(env,{...dependencies,requireEnabled:true}),/worker_preflight_failed/);
for(const changed of [{image_enabled:true},{unsupported_jobs_pending:true},{recipient:'Other provider'},{daily_global_units:11},{daily_user_units:5}]){
  await assert.rejects(workerPreflight(env,{...dependencies,query:async()=>({role_allowed:true,policy:{...policy,...changed}})}),/worker_preflight_failed/);
}
await assert.rejects(workerPreflight(env,{...dependencies,query:async()=>({role_allowed:false,policy})}),/worker_preflight_failed/);
await assert.rejects(workerPreflight({...env,PGSSLMODE:'disable'},dependencies),/worker_preflight_failed/);
await assert.rejects(workerPreflight({...env,AI_WORKER_OUTFIT_ONLY:'false'},dependencies),/worker_preflight_failed/);
assert.equal((await workerPreflight(env,{...dependencies,requireEnabled:true,
  query:async()=>({role_allowed:true,policy:{...policy,enabled:true,disclosure_matches:true}})})).enabled,true);
assert(calls>0);
console.log('OK: AI preflight rejects privileged roles, vision, unapproved budgets and disabled activation');

const imageEnv={...env,AI_WORKER_MODE:'images',AI_WORKER_OUTFIT_ONLY:'false'};
assert.equal((await workerPreflight(imageEnv,{...dependencies,requireEnabled:true,
 query:async()=>({role_allowed:true,policy:{...policy,enabled:true,image_enabled:true,disclosure_matches:true}})})).image_enabled,true);
assert.equal((await workerPreflight(imageEnv,dependencies)).image_enabled,false);
await assert.rejects(workerPreflight(imageEnv,{...dependencies,requireEnabled:true}),/worker_preflight_failed/);
