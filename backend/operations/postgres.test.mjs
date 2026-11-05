import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile,readdir } from 'node:fs/promises';
import { once } from 'node:events';
import { randomUUID } from 'node:crypto';
import { Pool } from 'pg';
import { generateKeyPair,exportJWK,SignJWT,createLocalJWKSet } from 'jose';
import { OperatorAuth,operatorConfiguration } from './auth.mjs';
import { OperatorStore } from './store.mjs';
import { createOperatorServer } from './server.mjs';
import { assertOperatorDatabaseRole } from './main.mjs';

test('signed MFA identity through HTTP uses only the dedicated database role and atomic audited writes',async t=>{
  assert.equal(process.env.OPS_PG_TESTS,'1','Opt in on a disposable local PostgreSQL cluster');
  const database=`szafa_ops_${process.pid}_${Date.now()}`,login=`${database}_login`;
  const admin=new Pool({database:'postgres',max:1});
  await admin.query(`CREATE DATABASE ${database}`);
  const owner=new Pool({database,max:1});let runtime;
  t.after(async()=>{if(runtime)await runtime.end();await owner.end();await admin.query(`DROP DATABASE ${database}`);
    await admin.query(`DROP ROLE IF EXISTS ${login}`);await admin.end();});
  await owner.query(await readFile(new URL('../tests/bootstrap.sql',import.meta.url),'utf8'));
  for(const file of (await readdir(new URL('../migrations/',import.meta.url))).filter(name=>/^\d{3}_.*\.sql$/.test(name)).sort())
    await owner.query(await readFile(new URL(`../migrations/${file}`,import.meta.url),'utf8'));
  await owner.query(await readFile(new URL('./bootstrap.sql',import.meta.url),'utf8'));
  const password=randomUUID();
  await owner.query(`CREATE ROLE ${login} LOGIN NOINHERIT PASSWORD '${password}'; GRANT szafa_ops TO ${login};`);
  runtime=new Pool({database,user:login,password,max:2});
  await assertOperatorDatabaseRole(runtime);
  await assert.rejects(assertOperatorDatabaseRole(owner),/operations_database_role_invalid/);
  await owner.query(`GRANT authenticated TO ${login}`);
  await assert.rejects(assertOperatorDatabaseRole(runtime),/operations_database_role_invalid/);
  await owner.query(`REVOKE authenticated FROM ${login}`);
  await assertOperatorDatabaseRole(runtime);
  await assert.rejects(runtime.query('SELECT * FROM app.garments'),{code:'42501'});
  await assert.rejects(runtime.query('SELECT * FROM ops_private.operators'),{code:'42501'});
  const issuer='https://identity.example',audience='szafa-operations';
  await owner.query(`INSERT INTO ops_private.operators(issuer,subject,role,enabled) VALUES($1,'admin','admin',true),($1,'viewer','viewer',true)`,[issuer]);
  const {privateKey,publicKey}=await generateKeyPair('ES256');
  const jwk={...await exportJWK(publicKey),kid:'test',alg:'ES256',use:'sig'};
  const auth=new OperatorAuth(operatorConfiguration({OPS_ISSUER:issuer,OPS_AUDIENCE:audience,OPS_JWKS_URL:`${issuer}/keys`,OPS_PUBLIC_ORIGIN:'https://ops.example'}),{keys:createLocalJWKSet({keys:[jwk]})});
  const token=async(sub,mfa=true)=>{const now=Math.floor(Date.now()/1000);return new SignJWT({iss:issuer,aud:audience,sub,jti:randomUUID(),iat:now,exp:now+300,auth_time:now,amr:mfa?['mfa']:['pwd']})
    .setProtectedHeader({alg:'ES256',kid:'test',typ:'at+jwt'}).sign(privateKey);};
  const server=createOperatorServer({auth,store:new OperatorStore(runtime),origin:'https://ops.example'});
  server.listen(0,'127.0.0.1');await once(server,'listening');
  t.after(()=>new Promise(resolve=>{server.closeAllConnections();server.close(resolve);}));
  const call=async(signed,command,id=randomUUID())=>{
    const response=await fetch(`http://127.0.0.1:${server.address().port}/api/command`,{method:'POST',headers:{
      Authorization:`Bearer ${signed}`,Origin:'https://ops.example','Content-Type':'application/json','Idempotency-Key':id},body:JSON.stringify(command)});
    return {status:response.status,body:await response.json()};};
  assert.equal((await call(await token('admin',false),{action:'summary'})).status,401);
  assert.equal((await call(await token('unknown'),{action:'summary'})).status,403);
  const adminToken=await token('admin'),viewerToken=await token('viewer');
  const initial=await call(viewerToken,{action:'summary'});assert.equal(initial.status,200);assert.equal(initial.body.data.role,'viewer');
  const change={action:'policy_update',version:initial.body.data.policy.version,enabled:false,imageEnabled:false,dailyGlobalUnits:1,dailyUserUnits:1};
  assert.equal((await call(viewerToken,change)).status,403);
  const id=randomUUID(),changed=await call(adminToken,change,id);assert.equal(changed.status,200);assert.equal(changed.body.data.version,2);
  assert.deepEqual(await call(adminToken,change,id),changed,'exact request replays without second change');
  assert.equal((await call(adminToken,{...change,enabled:true},id)).status,409);
  assert.equal((await call(adminToken,change)).status,409);
  const recorded=await owner.query("SELECT count(*)::int AS n FROM ops_private.audit WHERE action='policy_update' AND outcome='allowed'");
  assert.equal(recorded.rows[0].n,1);
  await owner.query("UPDATE ops_private.operators SET enabled=false WHERE subject='admin'");
  assert.equal((await call(adminToken,{action:'summary'})).status,403,'operator revocation overrides still-valid token');
  assert.equal((await owner.query('SELECT enabled,daily_global_units FROM api_private.ai_policy')).rows[0].enabled,false);
});
