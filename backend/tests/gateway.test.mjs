import test from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { once } from 'node:events';
import { randomUUID } from 'node:crypto';
import { ManagedAuth, GatewayError, bearer } from '../gateway/managed-auth.mjs';
import { createGateway } from '../gateway/server.mjs';

const owner = '10000000-0000-0000-0000-000000000001';
const sessionID = '20000000-0000-0000-0000-000000000001';
const cookie = 'synthetic-managed-session.signature%3D';
const baseURL = 'https://ep-test.neonauth.eu-central-1.aws.neon.tech/db/auth';
const close = server => new Promise(resolve => { server.closeAllConnections(); server.close(resolve); });
async function fixture(t) {
  const state = { active: true, verified: true, tombstoned: false, sent: 0, inspections: 0, calls: [] };
  const upstream = createServer(async (request, response) => {
    let body = '';
    for await (const chunk of request) body += chunk;
    state.calls.push({ path: request.url, headers: request.headers, body });
    response.setHeader('Content-Type', 'application/json');
    const send = value => response.end(JSON.stringify(value));
    if (request.url === '/db/auth/email-otp/send-verification-otp') { state.sent++; return send({ success: true }); }
    if (request.url === '/db/auth/sign-in/email-otp') {
      if (JSON.parse(body).otp !== '123456') { response.statusCode = 401; return send({ message: 'private-provider-details' }); }
      response.setHeader('Set-Cookie', [`__Secure-neonauth.session_token=${cookie}; HttpOnly; Secure; Path=/`, 'session_data=must-never-forward; Secure']);
      return send({ token: 'raw-provider-token-must-not-use', user: { id: owner } });
    }
    if (request.url === '/db/auth/get-session?disableCookieCache=true') {
      state.inspections++;
      if (!state.active || request.headers.cookie !== `__Secure-neonauth.session_token=${cookie}`) return send(null);
      return send({ session: { id: sessionID, userId: owner, expiresAt: new Date(Date.now()+3600000).toISOString() },
        user: { id: owner, email: 'person@example.test', emailVerified: state.verified, banned: false } });
    }
    if (request.url === '/db/auth/sign-out') {
      state.active = false;
      response.setHeader('Set-Cookie', '__Secure-neonauth.session_token=; Max-Age=0; Secure');
      return send({ success: true });
    }
    response.statusCode = 404; send({});
  });
  upstream.listen(0, '127.0.0.1'); await once(upstream, 'listening');
  t.after(() => close(upstream));
  const upstreamURL = `http://127.0.0.1:${upstream.address().port}`;
  const auth = new ManagedAuth({ baseURL, fetchImpl: (url, options) => {
    assert.equal(new URL(url).origin, new URL(baseURL).origin);
    assert.equal(options.redirect, 'error');
    return fetch(upstreamURL + new URL(url).pathname + new URL(url).search, options);
  } });
  const challenges = new Map();
  const store = {
    operations: new Set(['api_v1_list_garments']),
    challenge: async email => { const id = randomUUID(); challenges.set(id,email); return id; },
    attempt: async id => { if (!challenges.has(id)) throw new GatewayError('authentication_rejected',401); return challenges.get(id); },
    consume: async id => challenges.delete(id),
    session: async principal => {
      assert.equal(principal.owner, owner); assert.equal(principal.sessionID, sessionID);
      if (state.tombstoned) throw new GatewayError('unauthorized',401);
    },
    rpc: async (principal, operation, request) => ({ data: { owner: principal.owner, operation, request }, request_id: randomUUID() }),
  };
  const gateway = createGateway({ auth, store });
  gateway.listen(0,'127.0.0.1'); await once(gateway,'listening');
  t.after(() => close(gateway));
  const url = `http://127.0.0.1:${gateway.address().port}`;
  const call = (path, body, token) => fetch(url+path, { method:'POST', headers: {
    'Content-Type':'application/json', ...(token ? { Authorization:`Bearer ${token}` } : {}),
  }, body:JSON.stringify(body) });
  return { state, auth, store, call };
}

test('real HTTP bridge delegates OTP and returns only managed signed session cookie in existing DTO', async t => {
  const f = await fixture(t);
  const start = await f.call('/auth/v1/email/start', { email:'Person@Example.Test' });
  assert.equal(start.status,200);
  const {challengeID} = await start.json();
  const verified = await f.call('/auth/v1/email/verify',{challengeID,code:'123456'});
  assert.equal(verified.status,200);
  const session = await verified.json();
  assert.equal(session.userID,owner);
  assert.equal(session.accessToken,cookie); assert.equal(session.refreshToken,cookie);
  assert.equal(f.state.sent,1); assert.equal(f.state.inspections,1);
  assert(!JSON.stringify(session).includes('raw-provider-token'));
  assert(!f.state.calls.some(c=>c.headers.cookie?.includes('session_data')));
  assert.equal((await f.call('/auth/v1/email/verify',{challengeID,code:'123456'})).status,401);
});

test('each RPC requires current managed session and deletion gate; logout invalidates next request', async t => {
  const f=await fixture(t);
  const rpc=()=>f.call('/rest/v1/rpc/api_v1_list_garments',{request:{}},cookie);
  assert.equal((await rpc()).status,200); assert.equal((await rpc()).status,200);
  assert.equal(f.state.inspections,2);
  f.state.tombstoned=true;
  assert.equal((await rpc()).status,401);
  f.state.tombstoned=false;
  assert.equal((await f.call('/auth/v1/logout',{refreshToken:cookie})).status,200);
  assert.equal((await rpc()).status,401);
});

test('renewal uses managed session, rejects unverified identity and never exposes provider errors', async t => {
  const f=await fixture(t);
  const response=await f.call('/auth/v1/refresh',{refreshToken:cookie});
  assert.equal(response.status,200); assert.equal((await response.json()).accessToken,cookie);
  f.state.verified=false;
  assert.equal((await f.call('/auth/v1/refresh',{refreshToken:cookie})).status,401);
  const id=await f.store.challenge('person@example.test');
  const invalid=await f.call('/auth/v1/email/verify',{challengeID:id,code:'000000'});
  assert.equal(invalid.status,401); assert(!JSON.stringify(await invalid.json()).includes('private-provider-details'));
});

test('caller cannot choose RPC function, owner, auth origin, token headers or unbounded payload', async t => {
  const f=await fixture(t);
  assert.equal((await f.call('/rest/v1/rpc/api_v1_not_allowed',{request:{}},cookie)).status,404);
  assert.equal((await f.call('/rest/v1/rpc/api_v1_list_garments',{request:{},owner},cookie)).status,400);
  assert.equal((await f.call('/auth/v1/email/start',{email:'person@example.test',origin:'https://evil.test'})).status,400);
  assert.equal((await f.call('/auth/v1/refresh',{refreshToken:'x'.repeat(20000)})).status,413);
  for (const value of ['', 'Bearer short', `Bearer ${cookie}\r\nX-Fake: yes`, 'Bearer '+ 'x'.repeat(4097), 'Bearer token;other=value']) {
    assert.throws(()=>bearer(value),/unauthorized/);
  }
  for (const url of ['http://ep-test.neon.tech/db/auth','https://evil.test/auth','https://' + 'u:p@ep-test.neon.tech/db/auth','https://ep-test.neon.tech/db/auth?redirect=evil']) {
    assert.throws(()=>new ManagedAuth({baseURL:url}));
  }
});

test('checked-in RPC contracts reject duplicates, mismatched paths and malformed JSON at startup',async()=>{
 const {mkdtemp,writeFile,rm}=await import('node:fs/promises');
 const {tmpdir}=await import('node:os');
 const {pathToFileURL}=await import('node:url');
 const {join}=await import('node:path');
 const {loadRPCOperations}=await import('../gateway/contracts.mjs');
 const dir=await mkdtemp(join(tmpdir(),'szafa-contracts-'));const url=pathToFileURL(dir+'/');
 const document=operation=>JSON.stringify({openapi:'3.1.0',paths:{['/rest/v1/rpc/'+operation]:{post:{operationId:operation}}}});
 try {
   await assert.rejects(()=>loadRPCOperations(url),/core_contract_required/);
   await writeFile(join(dir,'openapi-v1.json'),document('api_v1_core'));
   await writeFile(join(dir,'openapi-ai-v1.json'),document('api_v1_generate_outfits'));
   assert.deepEqual((await loadRPCOperations(url)).sort(),['api_v1_core','api_v1_generate_outfits']);
   await writeFile(join(dir,'openapi-suggestions-v1.json'),document('api_v1_core'));
   await assert.rejects(()=>loadRPCOperations(url),/duplicate/);
   await writeFile(join(dir,'openapi-suggestions-v1.json'),document('api_v1_other').replace('/rest/v1/rpc/api_v1_other','/arbitrary'));
   await assert.rejects(()=>loadRPCOperations(url),/invalid/);
   await writeFile(join(dir,'openapi-suggestions-v1.json'),'{broken');
   await assert.rejects(()=>loadRPCOperations(url));
 }finally{await rm(dir,{recursive:true,force:true});}
});
