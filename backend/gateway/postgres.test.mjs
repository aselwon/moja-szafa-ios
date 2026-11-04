import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile, readdir } from 'node:fs/promises';
import { once } from 'node:events';
import { randomUUID } from 'node:crypto';
import { Pool } from 'pg';
import { GatewayStore } from './store.mjs';
import { loadRPCOperations } from './contracts.mjs';
import { createGateway } from './server.mjs';
import { GatewayError } from './managed-auth.mjs';

test('real PostgreSQL gateway bootstrap, owner isolation, replay, session revocation and deletion guards', async t => {
  // This suite creates/drops only its own uniquely named synthetic database.
  if (process.env.GATEWAY_PG_TESTS !== '1') throw new Error('Set GATEWAY_PG_TESTS=1 for a disposable PostgreSQL test cluster');
  const database = `szafa_gateway_${process.pid}_${Date.now()}`;
  const admin = new Pool({ database: 'postgres', max: 1 });
  await admin.query(`CREATE DATABASE ${database}`);
  const ownerPool = new Pool({ database, max: 2 });
  const runtimeRole = `${database}_login`;
  const runtimePassword = randomUUID();
  const runtime = new Pool({ database, max: 3, user: runtimeRole, password: runtimePassword });
  t.after(async () => {
    await runtime.end(); await ownerPool.end();
    await admin.query(`DROP DATABASE ${database}`);
    await admin.query(`DROP ROLE IF EXISTS ${runtimeRole}`); await admin.end();
  });
  // Test-only shape of provider-owned identity tables; never applied to Neon.
  await ownerPool.query(`CREATE SCHEMA neon_auth;
    CREATE TABLE neon_auth."user"(id uuid PRIMARY KEY, "emailVerified" boolean, banned boolean);
    CREATE TABLE neon_auth.session(id uuid PRIMARY KEY, "userId" uuid REFERENCES neon_auth."user"(id) ON DELETE CASCADE,
      "expiresAt" timestamptz, "impersonatedBy" text);`);
  const bootstrap = await readFile(new URL('../deploy/neon-bootstrap.sql', import.meta.url),'utf8');
  await ownerPool.query(bootstrap);
  await ownerPool.query(`CREATE ROLE ${runtimeRole} LOGIN NOINHERIT PASSWORD '${runtimePassword}'; GRANT szafa_gateway TO ${runtimeRole};`);
  await ownerPool.query(bootstrap); // Reapplication is safe before or after app migrations.
  for (const file of (await readdir(new URL('../migrations/',import.meta.url))).filter(f=>f.endsWith('.sql')).sort()) {
    await ownerPool.query(await readFile(new URL(`../migrations/${file}`,import.meta.url),'utf8'));
  }
  await ownerPool.query(bootstrap);
  const a = { owner:randomUUID(), sessionID:randomUUID() }, b = { owner:randomUUID(), sessionID:randomUUID() };
  for (const principal of [a,b]) {
    await ownerPool.query('INSERT INTO neon_auth."user" VALUES($1,true,false)',[principal.owner]);
    await ownerPool.query('INSERT INTO neon_auth.session VALUES($1,$2,now()+interval \'1 hour\',null)',[principal.sessionID,principal.owner]);
  }
  const store=new GatewayStore(runtime,await loadRPCOperations());
  const tokenA='synthetic-managed-owner-a.signature', tokenB='synthetic-managed-owner-b.signature';
  const auth={ current:async token=>{
    if(token===tokenA)return a; if(token===tokenB)return b; throw new GatewayError('unauthorized',401);
  }};
  const server=createGateway({auth,store});
  server.listen(0,'127.0.0.1'); await once(server,'listening');
  t.after(()=>new Promise(resolve=>{server.closeAllConnections();server.close(resolve);}));
  const call=async (operation,request,token=tokenA)=>{
    const response=await fetch(`http://127.0.0.1:${server.address().port}/rest/v1/rpc/${operation}`,{
      method:'POST',headers:{'Content-Type':'application/json',Authorization:`Bearer ${token}`},body:JSON.stringify({request})});
    return {status:response.status,body:await response.json()};
  };
  const garment=randomUUID(), operation=randomUUID();
  const payload={operation_id:operation,garment_id:garment,base_version:null,garment:{name:'Synthetic shirt',category:'top',price_grosz:12999,availability:'available'}};
  const first=await call('api_v1_save_garment',payload);
  assert.equal(first.status,200); assert(first.body.data,JSON.stringify(first.body));
  assert.deepEqual((await call('api_v1_save_garment',payload)).body,first.body,'timeout replay returns original response');
  assert.equal((await ownerPool.query('SELECT count(*)::int AS n FROM app.garments WHERE id=$1',[garment])).rows[0].n,1);
  const own=await call('api_v1_list_garments',{limit:20,cursor:null});
  const foreign=await call('api_v1_list_garments',{limit:20,cursor:null},tokenB);
  assert(JSON.stringify(own.body).includes(garment)); assert(!JSON.stringify(foreign.body).includes(garment));
  const forged=await call('api_v1_save_garment',{...payload,user_id:a.owner},tokenB);
  assert(forged.body.error); assert(!forged.body.data);
  assert.equal((await call('api_v1_not_allowed',{})).status,404);
  const image = await store.command(a,'images','prepare',{garment,id:randomUUID()});
  assert(image?.id);
  assert.equal(await store.command(b,'images','prepare',{owner:a.owner,garment,id:randomUUID()}),null,
    'privileged image commands must overwrite a supplied owner with the current session owner');
  await assert.rejects(store.command(a,'images','sweep',{}),/Unsupported operation/);
  await assert.rejects(runtime.query('SELECT * FROM neon_auth.session'),/permission denied/);
  await assert.rejects(runtime.query('SELECT * FROM auth.users'),/permission denied/);
  assert.equal((await runtime.query("SELECT nullif(current_setting('request.jwt.claim.sub',true),'') AS owner")).rows[0].owner,null,'identity does not leak through pool');

  // Provider HTTP may race revocation: database rechecks the session in the same transaction.
  await ownerPool.query('DELETE FROM neon_auth.session WHERE id=$1',[a.sessionID]);
  assert.equal((await call('api_v1_list_garments',{limit:20,cursor:null})).status,401);
  await ownerPool.query('INSERT INTO neon_auth.session VALUES($1,$2,now()+interval \'1 hour\',null)',[a.sessionID,a.owner]);
  await ownerPool.query('UPDATE app.profiles SET deleted_at=now() WHERE user_id=$1',[a.owner]);
  assert.equal((await call('api_v1_list_garments',{limit:20,cursor:null})).status,401);
  assert.equal((await call('api_v1_list_garments',{limit:20,cursor:null},tokenB)).status,200);

  const challenge=await store.challenge('synthetic@example.test');
  await assert.rejects(store.challenge('synthetic@example.test'),/rate_limited/);
  for(let i=0;i<5;i++)assert.equal(await store.attempt(challenge),'synthetic@example.test');
  await assert.rejects(store.attempt(challenge),/authentication_rejected/);
  const consumed=await store.challenge('another@example.test'); await store.consume(consumed);
  await assert.rejects(store.attempt(consumed),/authentication_rejected/);

  // Provider-native deletion cannot bypass app journal/photo cleanup.
  await assert.rejects(ownerPool.query('DELETE FROM neon_auth."user" WHERE id=$1',[b.owner]),/erasure authorization required/);
  const deletionID=randomUUID(), fence=randomUUID();
  await ownerPool.query(`INSERT INTO app.deletion_jobs(id,user_id,client_request_id,status,lease_token,lease_expires_at)
    VALUES($1,$2,$1,'running',$3,now()+interval '4 minutes')`,[deletionID,b.owner,fence]);
  await assert.rejects(runtime.query('SELECT gateway_private.approve_identity_erasure($1,$2,$3)',[b.owner,deletionID,fence]),/permission denied/);
  await assert.rejects(ownerPool.query('SELECT gateway_private.approve_identity_erasure($1,$2,$3)',[b.owner,deletionID,randomUUID()]),/Active deletion lease required/);
  await ownerPool.query('SELECT gateway_private.approve_identity_erasure($1,$2,$3)',[b.owner,deletionID,fence]);
  // After trusted cleanup authorization, exact UUID FK cascades compatibility identity.
  await ownerPool.query('DELETE FROM neon_auth."user" WHERE id=$1',[b.owner]);
  assert.equal((await ownerPool.query('SELECT count(*)::int AS n FROM auth.users WHERE id=$1',[b.owner])).rows[0].n,0);
  assert.equal((await call('api_v1_list_garments',{limit:20,cursor:null},tokenB)).status,401);
});
