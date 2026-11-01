// Offline structural guard only; database execution lives in test-database.sh.
import { readFile, readdir } from 'node:fs/promises';
import assert from 'node:assert/strict';
const directory = new URL('../backend/migrations/', import.meta.url);
const files = (await readdir(directory)).filter(name => name.endsWith('.sql')).sort();
assert.deepEqual(files, ['0001_wardrobe.sql', '0002_product.sql']);
const migrations = await Promise.all(files.map(name => readFile(new URL(name, directory), 'utf8')));
for (const sql of migrations) {
  assert.match(sql, /\bBEGIN;/);
  assert.match(sql, /COMMIT;\s*$/);
  assert.match(sql, /ENABLE ROW LEVEL SECURITY/);
  assert.match(sql, /FORCE ROW LEVEL SECURITY/);
  assert.doesNotMatch(sql, /DROP\s+(TABLE|SCHEMA)|DISABLE ROW LEVEL SECURITY/i);
}
const sql = migrations.join('\n');
const tables = [...sql.matchAll(/CREATE TABLE app\.(\w+)/g)].map(match => match[1]);
const expected = ['profiles','garments','garment_images','outfits','outfit_items','wear_events','wear_event_items','preferences','outfit_feedback','ai_jobs','consent_events','planned_outfits','trips','trip_items','purchase_candidates','subscription_entitlements','subscription_events','usage_reservations','sync_operations','deletion_jobs','support_requests','operator_audit','schema_migrations'];
assert.deepEqual(tables.sort(), expected.sort());
assert.match(sql, /FOREIGN KEY \(user_id, garment_id\) REFERENCES app.garments\(user_id, id\)/);
assert.match(sql, /UNIQUE \(user_id, client_request_id\)/);
assert.match(sql, /price_grosz bigint CHECK \(price_grosz >= 0\)/);
assert.match(sql, /INSERT INTO app.schema_migrations \(version\) VALUES \(2\)/);
const tests = await readFile(new URL('../backend/tests/contracts.sql', import.meta.url), 'utf8');
assert.match(tests, /SET LOCAL ROLE authenticated/);
assert.match(tests, /SET LOCAL ROLE service_role/);
console.log('OK: T008 migration structure (static only; PostgreSQL execution required separately)');
