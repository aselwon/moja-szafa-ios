import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile, readdir, mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { once } from 'node:events';
import { randomUUID } from 'node:crypto';
import { Pool } from 'pg';
import { GatewayStore } from './store.mjs';
import { loadRPCOperations } from './contracts.mjs';
import { createGateway } from './server.mjs';
import { GatewayError } from './managed-auth.mjs';
import { startImageRetention } from './image-retention.mjs';
import { privateFiles } from '../images/pipeline.mjs';

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
  await t.test('concurrent HTTP edits have one winner, explicit resolution and a durable deletion fence', async () => {
    const id = randomUUID();
    const created = await call('api_v1_save_garment', { ...payload, operation_id: randomUUID(), garment_id: id });
    assert.equal(created.body.data?.version, 1);
    const proposals = ['Client one', 'Client two'].map(name => ({ ...payload,
      operation_id: randomUUID(), garment_id: id, base_version: 1,
      garment: { ...payload.garment, name } }));
    const results = await Promise.all(proposals.map(input => call('api_v1_save_garment', input)));
    const winner = results.findIndex(result => result.body.data);
    assert.notEqual(winner, -1, JSON.stringify(results));
    const loser = 1 - winner;
    assert.equal(results[winner].body.data.version, 2);
    assert.equal(results[loser].body.error?.code, 'version_conflict', JSON.stringify(results));
    assert.equal(results.filter(result => result.body.data).length, 1, 'no silent last-writer-wins overwrite');
    const row = async () => (await ownerPool.query('SELECT name,version,deleted_at FROM app.garments WHERE id=$1', [id])).rows[0];
    assert.equal((await row()).name, proposals[winner].garment.name);
    // Resolving the loser requires a new operation against the winning version.
    const resolved = await call('api_v1_save_garment', { ...proposals[loser], operation_id: randomUUID(), base_version: 2 });
    assert.equal(resolved.body.data?.version, 3);
    assert.equal((await row()).name, proposals[loser].garment.name);
    assert.deepEqual((await call('api_v1_save_garment', proposals[winner])).body, results[winner].body,
      'an ambiguous old response replays without overwriting the resolved edit');
    assert.equal(Number((await row()).version), 3);
    const removed = await call('api_v1_delete_garment', { operationID: randomUUID(), garmentID: id });
    assert.equal(removed.body.data, true);
    const stale = await call('api_v1_save_garment', { ...proposals[loser], operation_id: randomUUID() });
    assert.equal(stale.body.error?.code, 'version_conflict');
    assert.ok((await row()).deleted_at, 'the stale request cannot resurrect the deleted UUID');
    assert.equal((await ownerPool.query('SELECT count(*)::int AS n FROM app.garments WHERE id=$1', [id])).rows[0].n, 1);
  });
  const signedAt = Date.now();
  const verifiedSubscription = { source: 'transaction', eventID: randomUUID(), digest: 'a'.repeat(64),
    eventType: 'TRANSACTION', eventSignedAt: signedAt, renewal: null,
    transaction: { environment: 'sandbox', owner: a.owner, transactionID: '1001', originalTransactionID: '1001',
      productID: 'test.monthly', purchasedAt: signedAt - 1000, expiresAt: signedAt + 3600000,
      signedAt, revokedAt: null, upgraded: false } };
  const subscription = await store.receiveSubscription(a, verifiedSubscription);
  assert.equal(subscription.transactionID, '1001'); assert.equal(subscription.entitlement.status, 'active');
  assert.equal((await store.receiveSubscription(a, verifiedSubscription)).duplicate, true);
  assert.equal((await store.subscriptionStatus(a, 'sandbox')).length, 1);
  assert.deepEqual(await store.subscriptionStatus(b, 'sandbox'), []);
  await assert.rejects(store.receiveSubscription(b, verifiedSubscription), error => error.code === 'subscription_account_mismatch');
  await assert.rejects(store.transaction(client => client.query('SELECT * FROM api_private.apple_subscription_transactions')), error => error.code === '42501');
  await assert.rejects(store.transaction(async client => {
    await store.bind(client, a); await client.query('SET LOCAL ROLE authenticated');
    await client.query('SELECT app.apple_subscription_receive($1::jsonb)', [JSON.stringify(verifiedSubscription)]);
  }), error => error.code === '42501');
  const forged=await call('api_v1_save_garment',{...payload,user_id:a.owner},tokenB);
  assert(forged.body.error); assert(!forged.body.data);
  assert.equal((await call('api_v1_not_allowed',{})).status,404);
  await ownerPool.query(`INSERT INTO api_private.ai_disclosure VALUES(true,'gateway-consent-test','Cloudflare Workers AI','Synthetic metadata','Synthetic integration test') ON CONFLICT(singleton) DO UPDATE SET policy_version=EXCLUDED.policy_version,recipient=EXCLUDED.recipient,data_description=EXCLUDED.data_description,purpose_description=EXCLUDED.purpose_description`);
  const disclosureResponse=await call('api_v1_ai_consent',{});
  assert.equal(disclosureResponse.status,200);
  const disclosure=disclosureResponse.body.data.disclosure;
  assert.equal(disclosure.policy_version,'gateway-consent-test');
  const choice={operation_id:randomUUID(),granted:true,disclosure};
  assert.equal((await call('api_v1_ai_consent',choice)).body.data.granted,true);
  assert.equal((await call('api_v1_ai_consent',choice)).body.data.granted,true);
  assert.equal((await call('api_v1_ai_consent',{},tokenB)).body.data.granted,false,'consent is owner isolated');
  assert.equal((await ownerPool.query('SELECT count(*)::int AS n FROM app.consent_events WHERE user_id=$1',[a.owner])).rows[0].n,1,'consent replay adds no event');
  assert.equal((await call('api_v1_ai_consent',{operation_id:randomUUID(),granted:false,disclosure:null})).body.data.granted,false);
  assert.equal((await call('api_v1_ai_consent',{},'invalid.synthetic')).status,401);

  const estimate={operationID:randomUUID(),id:garment,baseVersion:1,
    history:{count:10,startDate:'2026-01-02'},confirmOverlap:false};
  assert.equal((await call('api_v1_initial_wear_history',estimate,tokenB)).body.error?.code,'version_conflict');
  const estimated=await call('api_v1_initial_wear_history',estimate);
  assert.equal(estimated.status,200);
  assert.deepEqual(estimated.body.data?.metadata?.initialWearHistory,estimate.history,JSON.stringify(estimated.body));
  assert.deepEqual((await call('api_v1_initial_wear_history',estimate)).body,estimated.body);
  const detail=await call('api_v1_garment_detail',{id:garment});
  assert.deepEqual(detail.body.data.garment.initialWearHistory,estimate.history);

  // T038: the native history contract must pass the managed gateway and its
  // restricted database role, including replay and cross-account rejection.
  const wearID=randomUUID();
  assert((await call('api_v1_save_wear',{operationID:randomUUID(),wear:{id:wearID,version:0,deleted:false,
    wornOn:'2026-01-01',timezone:'Pacific/Kiritimati',garmentIDs:[garment]}})).body.data);
  const removal={operationID:randomUUID(),id:wearID,baseVersion:1,action:'remove'};
  const removed=await call('api_v1_wear_visibility',removal);
  assert.equal(removed.status,200);
  assert.equal(removed.body.data?.deleted,true,JSON.stringify(removed.body));
  assert.deepEqual((await call('api_v1_wear_visibility',removal)).body,removed.body);
  const restoration={operationID:randomUUID(),id:wearID,baseVersion:2,action:'restore'};
  assert.equal((await call('api_v1_wear_visibility',restoration,tokenB)).body.error?.code,'version_conflict');
  const restored=await call('api_v1_wear_visibility',restoration);
  assert.equal(restored.body.data?.deleted,false,JSON.stringify(restored.body));
  assert.equal(restored.body.data?.wornOn,'2026-01-01');
  assert.deepEqual(restored.body.data?.garmentIDs,[garment]);

  const tripOutfit=randomUUID(), tripID=randomUUID();
  const savedTripOutfit=await call('api_v1_save_outfit',{operationID:randomUUID(),id:tripOutfit,baseVersion:0,name:'Synthetic trip outfit',favorite:false,garmentIDs:[garment]});
  assert.equal(savedTripOutfit.body.data?.version,1,JSON.stringify(savedTripOutfit.body));
  const tripRequest={action:'save',operationID:randomUUID(),id:tripID,baseVersion:0,
    trip:{destination:'Synthetic destination',startsOn:'2026-11-01',endsOn:'2026-11-01',timezone:'Europe/Warsaw',occasions:['casual'],maxItems:1,
      days:[{day:'2026-11-01',outfitID:tripOutfit,outfitVersion:1}]}};
  const tripSaved=await call('api_v1_trips',tripRequest);
  assert.equal(tripSaved.body.data?.version,1,JSON.stringify(tripSaved.body));
  assert.deepEqual((await call('api_v1_trips',tripRequest)).body,tripSaved.body);
  assert.equal((await call('api_v1_trips',{action:'get',id:tripID},tokenB)).body.error?.code,'not_found');
  const wearBeforePacking=(await ownerPool.query('SELECT count(*)::int AS n FROM app.wear_events WHERE user_id=$1',[a.owner])).rows[0].n;
  const packing={action:'pack',operationID:randomUUID(),id:tripID,baseVersion:1,garmentID:garment,packed:true};
  const packedTrip=await call('api_v1_trips',packing);
  assert.equal(packedTrip.body.data?.version,2,JSON.stringify(packedTrip.body));
  assert.deepEqual((await call('api_v1_trips',packing)).body,packedTrip.body);
  assert.equal((await ownerPool.query('SELECT count(*)::int AS n FROM app.wear_events WHERE user_id=$1',[a.owner])).rows[0].n,wearBeforePacking);
  const prefs = {action:'preferences',operationID:randomUUID(),baseVersion:0,excludedCategories:['top'],colors:['blue']};
  const personalized=await call('api_v1_personalization',prefs);
  assert.equal(personalized.status,200);
  assert.equal(personalized.body.data?.version,1,JSON.stringify(personalized.body));
  assert.deepEqual((await call('api_v1_personalization',prefs)).body,personalized.body);
  assert.deepEqual((await call('api_v1_personalization',{action:'get'},tokenB)).body.data?.excludedCategories,[]);
  const reset=await call('api_v1_personalization',{action:'reset',operationID:randomUUID(),baseVersion:1});
  assert.equal(reset.body.data?.version,2);
  assert.deepEqual(reset.body.data?.excludedCategories,[]);
  assert.equal((await call('api_v1_personalization',{...prefs,operationID:randomUUID()})).body.error?.code,'version_conflict');

  const expiredExport = randomUUID(), liveExport = randomUUID();
  await store.command(a,'exports','prepare',{id:expiredExport});
  await store.command(b,'exports','prepare',{id:liveExport});
  await ownerPool.query("UPDATE api_private.data_exports SET expires_at=now()-interval '1 second' WHERE id=$1",[expiredExport]);
  const liveBefore = (await ownerPool.query('SELECT snapshot FROM api_private.data_exports WHERE id=$1',[liveExport])).rows[0].snapshot;
  await store.pruneExports();
  assert.equal((await ownerPool.query('SELECT snapshot FROM api_private.data_exports WHERE id=$1',[expiredExport])).rows[0].snapshot,null);
  assert.deepEqual((await ownerPool.query('SELECT snapshot FROM api_private.data_exports WHERE id=$1',[liveExport])).rows[0].snapshot,liveBefore);
  assert.equal(await store.command(a,'exports','prepare',{id:expiredExport}),null,'cleanup retains expiry tombstones against replay');
  await assert.rejects(store.command(a,'exports','sweep',{}),/Unsupported operation/);
  await assert.rejects(store.transaction(client=>client.query('SELECT * FROM api_private.data_exports')),error=>error.code==='42501');
  await assert.rejects(store.transaction(client=>client.query("SELECT app.exports_command('{\"action\":\"read\"}')")),error=>error.code==='42501');
  await assert.rejects(store.transaction(async client=>{
    await client.query('SET LOCAL ROLE authenticated');
    await client.query('SELECT gateway_private.prune_exports()');
  }),error=>error.code==='42501');

  const image = await store.command(a,'images','prepare',{garment,id:randomUUID()});
  assert(image?.id);
  assert.equal(await store.command(b,'images','prepare',{owner:a.owner,garment,id:randomUUID()}),null,
    'privileged image commands must overwrite a supplied owner with the current session owner');
  await assert.rejects(store.command(a,'images','sweep',{}),/Unsupported operation/);
  const recognitionDraft=randomUUID(), recognitionImage=randomUUID();
  const garmentCount=(await ownerPool.query('SELECT count(*)::int AS n FROM app.garments')).rows[0].n;
  assert.equal((await store.command(a,'recognition_images','prepare',{garment:recognitionDraft,id:recognitionImage})).id,recognitionImage);
  assert.equal(await store.command(b,'recognition_images','prepare',{owner:a.owner,garment:recognitionDraft,id:recognitionImage}),null);
  const recognitionClaim=await store.command(a,'recognition_images','claim',{id:recognitionImage});
  assert.equal(recognitionClaim.state,'processing');
  assert.equal(await store.command(a,'recognition_images','finish',{id:recognitionImage,fence:recognitionClaim.fence}),true);
  assert.equal(await store.command(a,'recognition_images','read',{id:recognitionImage,variant:'thumbnail'}),true);
  assert.equal(await store.command(b,'recognition_images','read',{owner:a.owner,id:recognitionImage,variant:'thumbnail'}),null);
  assert.equal((await ownerPool.query('SELECT count(*)::int AS n FROM app.garments')).rows[0].n,garmentCount,'private recognition upload never saves a garment');
  await assert.rejects(store.command(a,'recognition_images','sweep',{}),/Unsupported operation/);
  const discarded=await call('api_v1_recognition',{action:'discard',draft_id:recognitionDraft});
  assert.equal(discarded.body.data?.discarded,true,JSON.stringify(discarded.body));
  assert.equal(await store.command(a,'recognition_images','read',{id:recognitionImage,variant:'thumbnail'}),null);
  const deleted = await call('api_v1_delete_garment',{operationID:randomUUID(),garmentID:garment});
  assert.equal(deleted.status,200);
  assert.equal(deleted.body.data,true,'native camelCase delete payload reaches the canonical gateway route and SQL');
  // Exercise the deployed scheduler composition against real PostgreSQL and disk.
  const retainedGarment=randomUUID(), retainedImage=randomUUID();
  const retainedSave=await call('api_v1_save_garment',{operation_id:randomUUID(),garment_id:retainedGarment,base_version:null,
    garment:{name:'Retained shirt',category:'top',price_grosz:null,availability:'available'}},tokenB);
  assert(retainedSave.body.data,JSON.stringify(retainedSave.body));
  await store.command(b,'images','prepare',{garment:retainedGarment,id:retainedImage,has_cleaned:true});
  const retainedClaim=await store.command(b,'images','claim',{id:retainedImage});
  await store.command(b,'images','finish',{id:retainedImage,fence:retainedClaim.fence});
  const imageDirectory=await mkdtemp(join(tmpdir(),'szafa-retention-pg-'));
  t.after(()=>rm(imageDirectory,{recursive:true,force:true}));
  const imageStorage=privateFiles(imageDirectory);
  for(const id of [image.id,recognitionImage,retainedImage]) {
    for(const variant of ['original.jpg','thumbnail.jpg','cleaned.png']) await imageStorage.put(`${id}/${variant}`,Buffer.from('synthetic-image-bytes'));
  }
  await store.acknowledgeRetiredImage(retainedImage);
  assert.equal(await store.command(b,'images','read',{id:retainedImage,variant:'cleaned'}),true,'acknowledgement cannot delete a live image');
  let retentionErrors=0;
  const retention=startImageRetention({store,directory:imageDirectory,onError:()=>retentionErrors++});
  t.after(()=>retention.stop());
  await retention.ready; await retention.stop();
  assert.equal(retentionErrors,0);
  for(const id of [image.id,recognitionImage]) for(const variant of ['original.jpg','thumbnail.jpg','cleaned.png']) {
    await assert.rejects(imageStorage.get(`${id}/${variant}`),error=>error.code==='ENOENT');
  }
  for(const variant of ['original.jpg','thumbnail.jpg','cleaned.png']) assert.equal((await imageStorage.get(`${retainedImage}/${variant}`)).toString(),'synthetic-image-bytes');
  assert.equal((await ownerPool.query('SELECT state FROM api_private.image_uploads WHERE id=$1',[image.id])).rows[0].state,'retired');
  await assert.rejects(store.transaction(client=>client.query("SELECT app.images_command('{\"action\":\"sweep\"}')")),error=>error.code==='42501');
  await assert.rejects(store.transaction(async client=>{
    await client.query('SET LOCAL ROLE authenticated'); await client.query('SELECT gateway_private.retired_images()');
  }),error=>error.code==='42501');
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
