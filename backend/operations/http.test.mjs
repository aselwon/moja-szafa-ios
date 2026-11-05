import test from 'node:test';
import assert from 'node:assert/strict';
import { once } from 'node:events';
import { randomUUID } from 'node:crypto';
import { createOperatorServer } from './server.mjs';
import { OperatorError } from './auth.mjs';

test('operations HTTP requires identity, exact origin and bounded allowlisted commands',async t=>{
  const calls=[]; const actor={issuer:'https://identity.example',subject:'operator'};
  let denied=false;
  const store={command:async(who,id,command)=>{
    calls.push({who,id,command});
    if(denied)return {error:{code:'operator_denied'}};
    return {data:command.action==='summary'?{database:'ok',aiCalls:[],policy:{enabled:false},role:'viewer'}:{ok:true}};
  }};
  const auth={authenticate:async token=>{if(token!=='signed-test-token')throw new OperatorError('operator_authentication_required');return actor;}};
  const server=createOperatorServer({auth,store,origin:'https://ops.example'});
  server.listen(0,'127.0.0.1');await once(server,'listening');
  t.after(()=>new Promise(resolve=>{server.closeAllConnections();server.close(resolve);}));
  const url=`http://127.0.0.1:${server.address().port}`;
  const post=(payload,headers={})=>fetch(`${url}/api/command`,{method:'POST',headers:{Authorization:'Bearer signed-test-token',Origin:'https://ops.example',
    'Content-Type':'application/json','Idempotency-Key':randomUUID(),...headers},body:typeof payload==='string'?payload:JSON.stringify(payload)});
  assert.equal((await fetch(url)).status,401);
  assert.equal((await post({action:'summary'},{Origin:'https://evil.example'})).status,403);
  assert.equal((await post({action:'summary'},{Origin:''})).status,403);
  assert.equal((await post({action:'summary'},{Authorization:'Bearer invalid'})).status,401);
  assert.equal((await post({action:'impersonate'})).status,400);
  assert.equal((await post({action:'summary',padding:'x'.repeat(5000)})).status,413);
  assert.equal((await post({action:'summary'},{'Idempotency-Key':'not-an-id'})).status,400);
  assert.equal(calls.length,0,'untrusted requests never reach database');
  const good=await post({action:'summary'});assert.equal(good.status,200);
  assert.equal((await good.json()).data.cost.invoice_cost_usd,null,'estimate is not an invoice');
  assert.deepEqual(calls[0].who,actor);
  assert.equal(good.headers.get('cache-control'),'no-store');
  assert.match(good.headers.get('content-security-policy'),/frame-ancestors 'none'/);
  const page=await fetch(`${url}/`,{headers:{Authorization:'Bearer signed-test-token'}});
  assert.equal(page.status,200);assert.match(await page.text(),/Operations/);
  assert.equal((await fetch(`${url}/photos`,{headers:{Authorization:'Bearer signed-test-token'}})).status,404);
  denied=true;
  assert.equal((await fetch(`${url}/`,{headers:{Authorization:'Bearer signed-test-token'}})).status,403,'revoked operator cannot load UI');
  assert.equal((await post({action:'policy_update'})).status,403);
});

test('HTTP store failures never expose database or token details',async t=>{
  const server=createOperatorServer({origin:'https://ops.example',auth:{authenticate:async()=>({issuer:'x',subject:'y'})},
    store:{command:async()=>{throw new Error('PRIVATE CONNECTION STRING');}}});
  server.listen(0,'127.0.0.1');await once(server,'listening');
  t.after(()=>new Promise(resolve=>{server.closeAllConnections();server.close(resolve);}));
  const response=await fetch(`http://127.0.0.1:${server.address().port}/`,{headers:{Authorization:'Bearer synthetic'}});
  assert.equal(response.status,503);assert.doesNotMatch(await response.text(),/PRIVATE/);
});
