import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
const read = path => readFile(new URL(`../${path}`, import.meta.url), 'utf8');
const contract = JSON.parse(await read('backend/api/openapi-v1.json'));
assert.equal(contract.openapi, '3.1.0');
assert.equal(contract.info.version, '1.0.0');
const schemas = contract.components.schemas;
function visit(value) {
  if (!value || typeof value !== 'object') return;
  if (value.$ref) assert(schemas[value.$ref.split('/').at(-1)], `Unresolved ${value.$ref}`);
  for (const child of Object.values(value)) visit(child);
}
visit(contract);
const sql = (
  await Promise.all(
    ['003_api.sql', '004_offline_sync.sql', '006_jobs.sql'].map(name => read(`backend/migrations/${name}`)),
  )
).join('\n');
const swift = await read('MojaSzafa/Data/APIClient.swift') + await read('MojaSzafa/Data/OfflineStore.swift');
const fixSql = await read('backend/migrations/005_fix_save_garment.sql');
for (const route of Object.values(contract.paths)) {
  const operation = route.post.operationId;
  assert(sql.includes(`CREATE FUNCTION app.${operation}(request jsonb)`));
  assert(swift.includes(`"${operation}"`));
  assert(route.post.responses['200'].content['application/json'].schema.oneOf.length === 2);
}
for (const field of ['operation_id', 'garment_id', 'base_version', 'price_grosz', 'next_cursor', 'request_id']) {
  assert(swift.includes(`"${field}"`));
  assert(sql.includes(`'${field}'`));
}
assert.equal(schemas.PageRequest.properties.limit.maximum, 100);
assert.deepEqual(schemas.SaveGarment.required, ['operation_id', 'garment_id', 'base_version', 'garment']);
assert.equal(schemas.SaveGarment.additionalProperties, false);
assert(sql.includes('PRIMARY KEY (user_id, operation_id)'));
assert(sql.includes('ON CONFLICT DO NOTHING'));
assert(sql.includes('previous.request <> request'));
assert(fixSql.includes('CREATE OR REPLACE FUNCTION app.api_v1_save_garment(request jsonb)'));
assert(fixSql.includes('v_operation_id uuid'));
assert(!fixSql.includes('api_v1_save_garment.operation_id'));
console.log('OK: T009 OpenAPI references, RPC/Swift surface and replay contract (structural; not runtime tests)');
