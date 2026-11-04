import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
const contract = JSON.parse(await readFile(new URL('../backend/api/openapi-trips-v1.json', import.meta.url), 'utf8'));
const schemas = contract.components.schemas;
function visit(value) {
  if (!value || typeof value !== 'object') return;
  if (value.$ref) assert(schemas[value.$ref.split('/').at(-1)]);
  Object.values(value).forEach(visit);
}
visit(contract);
for (const name of ['ListTrips','GetTrip','SaveTrip','PackTrip','TripBody','TripChoice']) {
  assert.equal(schemas[name].additionalProperties, false);
  assert(!schemas[name].properties.user_id);
}
assert.equal(schemas.TripBody.properties.maxItems.maximum, 100);
assert.equal(schemas.TripBody.properties.days.maxItems, 30);
assert.equal(schemas.TripPageSuccess.properties.data.properties.items.maxItems, 20);
assert.deepEqual(schemas.TripChoice.required, ['day','outfitID','outfitVersion']);
console.log('OK: standalone bounded trip packing contract');
