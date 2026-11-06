import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile, readdir } from 'node:fs/promises';
import { randomUUID, createHash } from 'node:crypto';
import { Pool } from 'pg';
import { createServer } from 'node:http';
import { once } from 'node:events';
import { ManagedAuth } from './managed-auth.mjs';
import { GatewayStore } from './store.mjs';
import { createGateway } from './server.mjs';
import { neonErasureStore } from '../deletion/adapters/neon-store.mjs';

test('erasure role enforces live lease, owner isolation and managed identity absence', async t => {
  if (process.env.GATEWAY_PG_TESTS !== '1') throw new Error('Disposable PostgreSQL required');
  const database = `szafa_erasure_${process.pid}_${Date.now()}`;
  const admin = new Pool({ database: 'postgres', max: 1 });
  await admin.query(`CREATE DATABASE ${database}`);
  const db = new Pool({ database, max: 1 });
  const role = `${database}_login`, password = randomUUID();
  const runtime = new Pool({ database, user: role, password, max: 1 });
  let gatewayPool, gatewayRole;
  const servers = [];
  t.after(async () => {
    for (const server of servers) { server.closeAllConnections(); await new Promise(resolve => server.close(resolve)); }
    await gatewayPool?.end();
    await runtime.end(); await db.end();
    await admin.query(`DROP DATABASE ${database}`);
    if (gatewayRole) await admin.query(`DROP ROLE IF EXISTS ${gatewayRole}`);
    await admin.query(`DROP ROLE IF EXISTS ${role}`); await admin.end();
  });
  // Only this disposable database receives synthetic provider tables/users.
  await db.query(`CREATE SCHEMA neon_auth;
    CREATE TABLE neon_auth."user"(id uuid PRIMARY KEY, "emailVerified" boolean, banned boolean,email text);
    CREATE TABLE neon_auth.session(id uuid PRIMARY KEY, "userId" uuid REFERENCES neon_auth."user" ON DELETE CASCADE,
      "expiresAt" timestamptz, "updatedAt" timestamptz, "impersonatedBy" text,"createdAt" timestamptz DEFAULT clock_timestamp());
    CREATE TABLE neon_auth.account(id uuid PRIMARY KEY,"userId" uuid REFERENCES neon_auth."user" ON DELETE CASCADE,"providerId" text);`);
  await db.query(await readFile(new URL('../deploy/neon-bootstrap.sql', import.meta.url), 'utf8'));
  for (const file of (await readdir(new URL('../migrations/', import.meta.url))).filter(name => name.endsWith('.sql')).sort()) {
    await db.query(await readFile(new URL(`../migrations/${file}`, import.meta.url), 'utf8'));
  }
  const sql = await readFile(new URL('../deploy/neon-erasure.sql', import.meta.url), 'utf8');
  await db.query(sql); await db.query(sql);
  const reauthSQL = await readFile(new URL('../deploy/neon-deletion-reauth.sql', import.meta.url), 'utf8');
  await db.query(reauthSQL); await db.query(reauthSQL);
  await db.query(`CREATE ROLE ${role} LOGIN NOINHERIT PASSWORD '${password}'; GRANT szafa_erasure TO ${role};`);
  const libpq=neonErasureStore({environment:{...process.env,PGDATABASE:database,PGUSER:role,PGPASSWORD:password}});
  await libpq.verifyRole();
  await assert.rejects(neonErasureStore({environment:{...process.env,PGDATABASE:database}}).verifyRole(),/least_privilege_erasure_role_required/);
  const owner = randomUUID(), other = randomUUID();
  for (const user of [owner, other]) {
    await db.query('INSERT INTO neon_auth."user" VALUES($1,true,false,$2)', [user, `${user}@example.test`]);
    await db.query('INSERT INTO auth.users VALUES($1)', [user]);
    await db.query('INSERT INTO app.profiles(id,user_id) VALUES($1,$1)', [user]);
    await db.query('INSERT INTO neon_auth.session(id,"userId","expiresAt","updatedAt","impersonatedBy") VALUES($1,$2,now()+interval \'1 hour\',now(),null)', [randomUUID(), user]);
  }
  await db.query('SELECT app.deletion_command($1)', [JSON.stringify({ action: 'request', owner, id: randomUUID() })]);
  async function call(action, args = {}) {
    const client = await runtime.connect();
    try {
      await client.query('BEGIN'); await client.query('SET LOCAL ROLE szafa_erasure');
      const result = await client.query('SELECT gateway_private.erasure_command($1) AS result', [JSON.stringify({ ...args, action })]);
      await client.query('COMMIT'); return result.rows[0].result;
    } catch (error) { await client.query('ROLLBACK'); throw error; }
    finally { client.release(); }
  }
  await assert.rejects(runtime.query('SELECT * FROM neon_auth.session'), /permission denied/);
  const job = await call('claim');
  assert.equal(job.owner, owner);
  let context = { ...job, job: job.id };
  assert.equal(await call('assertLease', context), true);
  assert.equal(await libpq.assertLease(owner,{job:job.id,fence:job.fence,signal:new AbortController().signal}),true,'actual libpq worker adapter binds JSON and role correctly');
  assert.equal(await call('assertLease', { ...context, owner: other }), false);
  await call('deferReplica',context);
  const deferred=(await db.query('SELECT status,attempts,error_code FROM app.deletion_jobs WHERE id=$1',[job.id])).rows[0];
  assert.deepEqual(deferred,{status:'queued',attempts:0,error_code:'backup_replica_unavailable'});
  assert.equal(await call('assertLease',context),false);
  await db.query('UPDATE app.deletion_jobs SET available_at=clock_timestamp() WHERE id=$1',[job.id]);
  const reclaimed=await call('claim'); context={...reclaimed,job:reclaimed.id};
  await assert.rejects(call('revokeSessions', { ...context, fence: randomUUID() }), /Active deletion lease required/);
  await call('revokeSessions', context);
  for (const [user, expected] of [[owner, 0], [other, 1]]) {
    assert.equal((await db.query('SELECT count(*)::int AS n FROM neon_auth.session WHERE "userId"=$1 AND "expiresAt">now()', [user])).rows[0].n, expected);
  }
  assert.equal(await call('hasAppleIdentity', context), false);
  await db.query('INSERT INTO neon_auth.account VALUES($1,$2,\'apple\')', [randomUUID(), owner]);
  assert.equal(await call('hasAppleIdentity', context), true);
  assert.equal(await call('identityAbsent', context), false);
  await assert.rejects(call('finish', context), /Managed identity remains/);
  await assert.rejects(db.query('DELETE FROM neon_auth."user" WHERE id=$1', [owner]), /erasure authorization required/);
  await call('approveDeletion', context);
  await db.query('DELETE FROM neon_auth."user" WHERE id=$1', [owner]);
  assert.equal(await call('identityAbsent', context), true);
  assert.equal(await call('finish', context), true);
  assert.equal(await call('assertLease', context), false);
  assert.equal((await db.query('SELECT count(*)::int AS n FROM neon_auth."user" WHERE id=$1', [other])).rows[0].n, 1);

  // Full local HTTP -> ManagedAuth OTP/cookie bridge -> real PostgreSQL flow.
  // Only the external provider is synthetic; no successful reauth assertion is
  // stubbed inside the app, and all ownership/expiry/consumption checks run SQL.
  gatewayRole = `${database}_gateway`;
  const gatewayPassword = randomUUID();
  await db.query(`CREATE ROLE ${gatewayRole} LOGIN NOINHERIT PASSWORD '${gatewayPassword}'; GRANT szafa_gateway TO ${gatewayRole};`);
  gatewayPool = new Pool({ database, user: gatewayRole, password: gatewayPassword, max: 2 });
  const existing = (await db.query('SELECT id FROM neon_auth.session WHERE "userId"=$1', [other])).rows[0].id;
  const originalToken = 'synthetic-original-managed-session.signature';
  const sessions = new Map([[originalToken, existing]]);
  let sent = 0, verified = 0;
  const upstream = createServer(async (request, response) => {
    response.setHeader('Content-Type','application/json');
    const send = value => response.end(JSON.stringify(value));
    let text = ''; for await (const chunk of request) text += chunk;
    const payload = text ? JSON.parse(text) : null;
    const token = request.headers.cookie?.split('=',2)[1];
    if (request.url === '/db/auth/email-otp/send-verification-otp') {
      assert.equal(payload.email, `${other}@example.test`); assert.equal(payload.type,'sign-in'); sent++; return send({success:true});
    }
    if (request.url === '/db/auth/sign-in/email-otp') {
      verified++;
      if (payload.otp !== '123456') { response.statusCode=401; return send({message:'rejected'}); }
      const fresh = randomUUID(), cookie = `synthetic-fresh-${fresh}.signature`;
      await db.query('INSERT INTO neon_auth.session(id,"userId","expiresAt","updatedAt") VALUES($1,$2,now()+interval \'1 hour\',now())',[fresh,other]);
      sessions.set(cookie,fresh);
      response.setHeader('Set-Cookie',`__Secure-neon-auth.session_token=${cookie}; Secure; HttpOnly`);
      return send({token:'unused-raw-token',user:{id:other}});
    }
    if (request.url === '/db/auth/get-session?disableCookieCache=true') {
      const session = (await db.query('SELECT id,"userId","expiresAt" FROM neon_auth.session WHERE id=$1 AND "expiresAt">clock_timestamp()',[sessions.get(token) ?? null])).rows[0];
      return send(session ? {session,user:{id:other,email:`${other}@example.test`,emailVerified:true}} : null);
    }
    if (request.url === '/db/auth/sign-out') { sessions.delete(token); return send({success:true}); }
    response.statusCode=404; send({});
  });
  upstream.listen(0,'127.0.0.1'); await once(upstream,'listening');
  servers.push(upstream);
  const auth = new ManagedAuth({baseURL:'https://ep-synthetic.neon.tech/db/auth',fetchImpl:(url,options)=>fetch(`http://127.0.0.1:${upstream.address().port}${new URL(url).pathname}${new URL(url).search}`,options)});
  const gatewayStore = new GatewayStore(gatewayPool,['api_v1_list_garments']);
  const gateway = createGateway({auth,store:gatewayStore,deletionEnabled:true});
  gateway.listen(0,'127.0.0.1'); await once(gateway,'listening');
  servers.unshift(gateway);
  const post = (path,body,token=originalToken)=>fetch(`http://127.0.0.1:${gateway.address().port}${path}`,{method:'POST',headers:{Authorization:`Bearer ${token}`,'Content-Type':'application/json'},body:body===undefined?undefined:JSON.stringify(body)});
  assert.equal((await post('/v1/account/deletion/challenge',undefined,'invalid-token')).status,401);
  assert.equal(sent,0);
  const start=await post('/v1/account/deletion/challenge'); assert.equal(start.status,200);
  const challenge=await start.json(); assert.equal(challenge.method,'email'); assert.equal(sent,1);
  const operation=randomUUID();
  const statusBody={operation_id:operation,challenge_id:challenge.id};
  assert.match(challenge.receiptToken,/^[A-Za-z0-9_-]{43}$/);
  const capabilityBody={...statusBody,receipt_token:challenge.receiptToken};
  const storedHash=(await db.query('SELECT token_hash FROM gateway_private.deletion_receipts WHERE challenge_id=$1',[challenge.id])).rows[0].token_hash;
  assert.equal(storedHash,createHash('sha256').update(challenge.receiptToken).digest('hex'));
  assert.notEqual(storedHash,challenge.receiptToken);
  assert.deepEqual(await (await post('/v1/account/deletion/status',capabilityBody,'invalid-token')).json(),{accepted:false});
  assert.equal((await post('/v1/account/deletion/status',{...capabilityBody,receipt_token:'bad'},'invalid-token')).status,400);
  const pendingStatus=await post('/v1/account/deletion/status',statusBody);
  assert.equal(pendingStatus.status,200); assert.deepEqual(await pendingStatus.json(),{accepted:false});
  assert.equal((await db.query('SELECT attempts FROM gateway_private.deletion_challenges WHERE id=$1',[challenge.id])).rows[0].attempts,0,'status cannot consume an OTP attempt');
  const principal={owner:other,sessionID:existing};
  const secondSession=randomUUID();
  await db.query('INSERT INTO neon_auth.session(id,"userId","expiresAt","createdAt") VALUES($1,$2,now()+interval \'1 hour\',now()-interval \'1 day\')',[secondSession,other]);
  assert.equal(await gatewayStore.deletionReauthentication('attempt',{...principal,sessionID:secondSession},{challenge:challenge.id,operation}),null,'challenge is bound to its original session');
  assert((await gatewayStore.deletionReauthentication('attempt',principal,{challenge:challenge.id,operation})).email);
  assert.equal(await gatewayStore.deletionReauthentication('accept',principal,{challenge:challenge.id,operation,freshSession:secondSession}),null,'an old same-owner session is not fresh OTP proof');
  await db.query('DELETE FROM neon_auth.session WHERE id=$1',[secondSession]);
  const proof={operation_id:operation,proof:{challenge_id:challenge.id,code:'000000'}};
  assert.equal((await post('/v1/account/deletion',proof)).status,401);
  assert.equal((await db.query('SELECT count(*)::int AS n FROM app.deletion_jobs WHERE user_id=$1',[other])).rows[0].n,0);
  proof.proof.code='123456';
  const accepted=await post('/v1/account/deletion',proof); assert.equal(accepted.status,202);
  const receipt=await accepted.json(); assert.equal(receipt.status,'accepted');
  assert.deepEqual(await (await post('/v1/account/deletion',proof)).json(),receipt);
  assert.equal(verified,2,'receipt replay never consumes another OTP');
  assert.deepEqual(await (await post('/v1/account/deletion/status',statusBody)).json(),{accepted:true});
  assert.deepEqual(await (await post('/v1/account/deletion/status',{...statusBody,operation_id:randomUUID()})).json(),{accepted:false});
  assert.equal(verified,2,'status resumes a lost receipt without verifying another OTP');
  assert.equal((await post('/v1/account/deletion',{...proof,operation_id:randomUUID()})).status,403);
  assert.equal((await post('/rest/v1/rpc/api_v1_list_garments',{request:{limit:20,cursor:null}})).status,401);
  assert.equal((await db.query('SELECT count(*)::int AS n FROM neon_auth.session WHERE "userId"=$1 AND "expiresAt">clock_timestamp()',[other])).rows[0].n,1,'temporary proof session expired atomically');
  await db.query('UPDATE gateway_private.deletion_challenges SET created_at=clock_timestamp()-interval \'2 days\',expires_at=clock_timestamp()-interval \'1 day\' WHERE id=$1',[challenge.id]);
  const delayed=await post('/v1/account/deletion',proof);
  assert.equal(delayed.status,202,'accepted receipt remains replayable while original managed session is live');
  assert.deepEqual(await delayed.json(),receipt);
  assert.equal(verified,2,'delayed receipt replay does not consume another OTP');
  assert.equal((await post('/v1/account/deletion',{...proof,operation_id:randomUUID()})).status,403);
  assert.equal((await db.query('SELECT count(*)::int AS n FROM app.deletion_jobs WHERE user_id=$1',[other])).rows[0].n,1);
  const rateOwner=randomUUID(),rateSession=randomUUID();
  await db.query('INSERT INTO neon_auth."user" VALUES($1,true,false,$2)',[rateOwner,`${rateOwner}@example.test`]);
  await db.query('INSERT INTO neon_auth.session(id,"userId","expiresAt") VALUES($1,$2,now()+interval \'1 hour\')',[rateSession,rateOwner]);
  const ratePrincipal={owner:rateOwner,sessionID:rateSession};
  const rateChallenge=await gatewayStore.deletionReauthentication('start',ratePrincipal);
  assert((await db.query('SELECT receipt FROM gateway_private.deletion_challenges WHERE id=$1',[challenge.id])).rows[0]?.receipt,'starting another owner challenge must retain old consumed receipts');
  assert.equal(await gatewayStore.deletionReauthentication('start',ratePrincipal),null,'resend rate limit is durable across processes');
  const rateOperation=randomUUID();
  await db.query('UPDATE gateway_private.deletion_challenges SET expires_at=clock_timestamp()-interval \'1 second\' WHERE id=$1',[rateChallenge.id]);
  assert.equal(await gatewayStore.deletionReauthentication('attempt',ratePrincipal,{challenge:rateChallenge.id,operation:rateOperation}),null,'unconsumed expired proof still fails');
  await db.query('UPDATE gateway_private.deletion_challenges SET expires_at=clock_timestamp()+interval \'5 minutes\' WHERE id=$1',[rateChallenge.id]);
  for(let i=0;i<5;i++)assert((await gatewayStore.deletionReauthentication('attempt',ratePrincipal,{challenge:rateChallenge.id,operation:rateOperation})).email);
  assert.equal(await gatewayStore.deletionReauthentication('attempt',ratePrincipal,{challenge:rateChallenge.id,operation:rateOperation}),null,'bounded proof attempts');
  // The worker can erase provider identity before the client receives its 202.
  // Receipt recovery must still work without a session and cannot create a job.
  const finalJob=await call('claim'); assert.equal(finalJob.owner,other);
  const finalContext={...finalJob,job:finalJob.id};
  await call('revokeSessions',finalContext);
  await call('approveDeletion',finalContext);
  await db.query('DELETE FROM neon_auth."user" WHERE id=$1',[other]);
  assert.equal(await call('finish',finalContext),true);
  assert.equal((await post('/v1/account/deletion/status',statusBody)).status,401);
  const recovered=await fetch(`http://127.0.0.1:${gateway.address().port}/v1/account/deletion/status`,{
    method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(capabilityBody)});
  assert.equal(recovered.status,200); assert.deepEqual(await recovered.json(),{accepted:true});
  for (const mismatch of [{receipt_token:'A'.repeat(43)},{operation_id:randomUUID()},{challenge_id:randomUUID()}]) {
    assert.deepEqual(await (await post('/v1/account/deletion/status',{...capabilityBody,...mismatch},'invalid-token')).json(),{accepted:false});
  }
  assert.equal(sent,1); assert.equal(verified,2);
  assert.equal((await db.query('SELECT count(*)::int AS n FROM app.deletion_jobs WHERE user_id=$1',[other])).rows[0].n,1);

});
