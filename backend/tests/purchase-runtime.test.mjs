import test from 'node:test';
import assert from 'node:assert/strict';
import { createAIExecutor } from '../ai/executor.mjs';
import { createProvider, serverConfiguration } from '../ai/provider.mjs';
const wardrobe=[{id:'shoes',category:'shoes',user_id:'owner',availability:'available',archived:false}];
function fixture({change=false,revoke=false,foreign=false}={}) {
 let resolves=0,calls=0;const records=[];
 const provider=createProvider(serverConfiguration({AI_ENDPOINT:'https://fixture.invalid',AI_PROVIDER:'fixture',AI_RECIPIENT:'fixture',AI_API_KEY:'synthetic',AI_IMAGE_MODEL:'image',AI_OUTFIT_MODEL:'text'}),{fetchImpl:async(_url,req)=>{
  calls++;const b=JSON.parse(req.body);assert.equal(b.model,'text');assert.match(b.messages[0].content,/hypothetical purchase_candidate/);assert.doesNotMatch(b.messages[1].content,/image_url|base64|object_key/);
  return Response.json({model:'text',usage:{prompt_tokens:1,completion_tokens:1},choices:[{finish_reason:'stop',message:{content:JSON.stringify({outfits:[{garment_ids:[foreign?'foreign':'shoes'],rationale:'The shoes match the candidate dress.'}],shortfall_reason:'Only one combination available.'})}}]});
 }});
 const execute=createAIExecutor({provider,resolveInput:async()=>({garments:change&&resolves++>0?[]:wardrobe,purchase_candidate:{id:'candidate',category:'dress'},count:3}),authorize:async()=>!revoke,validateResult:async(_job,value)=>value,recordTelemetry:async r=>records.push(r)});
 return {run:()=>execute({id:'job',attempt:1,kind:'purchase_fit',user_id:'owner'}),calls:()=>calls,records};
}
test('purchase fit uses text model and keeps hypothetical item separate',async()=>{
 const f=fixture();const r=await f.run();assert.equal(r.outcome,'success');const outfit=r.output.result.outfits[0];assert.deepEqual(outfit.garment_ids,['shoes']);assert.equal(outfit.purchase_candidate_id,'candidate');assert.equal(outfit.complete,true);assert.equal(f.records[0].operation,'purchase_fit');
});
test('revoked consent prevents provider call; foreign or changed wardrobe results fail closed',async()=>{
 const denied=fixture({revoke:true});assert.equal((await denied.run()).outcome,'permanent');assert.equal(denied.calls(),0);
 for(const option of [{foreign:true},{change:true}])assert.equal((await fixture(option).run()).outcome,'permanent');
});

test('purchase image HTTP bridge binds verified owner and separate resource command',async t=>{
 const {createGateway}=await import('../gateway/server.mjs');const {once}=await import('node:events');const {randomUUID,randomBytes}=await import('node:crypto');
 const owner=randomUUID(),candidate=randomUUID(),image=randomUUID();const seen=[];
 const gateway=createGateway({auth:{current:async token=>{assert.equal(token,'synthetic-session-token');return {owner,sessionID:randomUUID()};}},
  store:{session:async()=>{},command:async(principal,kind,action,data)=>{seen.push({principal,kind,action,data});return {id:image};}},
  storage:{},signingKey:randomBytes(32)});
 gateway.listen(0,'127.0.0.1');await once(gateway,'listening');t.after(()=>{gateway.closeAllConnections();gateway.close();});
 const response=await fetch(`http://127.0.0.1:${gateway.address().port}/v1/purchase-images/uploads`,{method:'POST',headers:{Authorization:'Bearer synthetic-session-token','Content-Type':'application/json'},body:JSON.stringify({candidate_id:candidate,operation_id:image,owner:'forged'})});
 assert.equal(response.status,200);const body=await response.json();assert.match(body.upload_url,new RegExp('^/v1/purchase-images/uploads/'+image+'\\?token='));
 assert.equal(seen[0].kind,'purchase_images');assert.equal(seen[0].principal.owner,owner);assert.equal(seen[0].data.owner,owner);assert.equal(seen[0].data.garment,candidate);
});
