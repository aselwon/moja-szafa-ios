import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
const contract = JSON.parse(await readFile(new URL('../backend/api/openapi-planner-v1.json', import.meta.url), 'utf8'));
const schemas = contract.components.schemas;
function walk(value) {
  if (!value || typeof value !== 'object') return;
  if (value.$ref) assert(schemas[value.$ref.split('/').at(-1)], `Unresolved ${value.$ref}`);
  Object.values(value).forEach(walk);
}
walk(contract);
for (const name of ['ListPlans','CreatePlan','MovePlan','DeletePlan','RestorePlan','ConfirmPlan']) {
  assert.equal(schemas[name].additionalProperties, false);
  assert(!schemas[name].properties.user_id);
}
assert.deepEqual(Object.keys(schemas.ConfirmPlan.properties), ['action','operationID','id','baseVersion','outfitVersion']);
assert.equal(schemas.CreatePlan.properties.baseVersion.const, 0);
console.log('OK: planner standalone API contract');
