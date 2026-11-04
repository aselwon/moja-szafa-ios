import assert from 'node:assert/strict';
import { readFile, readdir } from 'node:fs/promises';

// Parallel tasks collide on migration numbers and Xcode object IDs; fail fast instead of in CI.
const root = new URL('../', import.meta.url);
const read = path => readFile(new URL(path, root), 'utf8');

const files = (await readdir(new URL('backend/migrations/', root))).filter(n => n.endsWith('.sql')).sort();
assert(files.length > 0, 'No migrations found');
assert(files.every(n => /^[0-9]{3}_[a-z0-9_]+\.sql$/.test(n)), 'Invalid migration filename');
const versions = files.map(n => n.slice(0, 3));
assert.equal(new Set(versions).size, versions.length, 'Duplicate migration version');
// Reserved versions may arrive in separate PRs. Already deployed migrations
// are immutable: a temporary gap is not permission to renumber them.
const last = versions.at(-1);
const migrate = await read('backend/migrate.sh');
assert(migrate.includes(`target=\${2:-${last}}`), `Default migration target must be ${last}`);
assert(migrate.includes(`|${last}]}`), `Migration usage must include ${last}`);
const accepted = migrate.match(/=~ (\^\(.+?\)\$) \]\]/);
assert(accepted && versions.every(v => new RegExp(accepted[1]).test(v)), 'Migration target regex must accept every checked-in version');
const schema = await read('backend/tests/schema.sql');
assert(schema.includes('count(*) = :expected_migration_count FROM migration_meta.versions'), 'Schema test must count checked-in files, not the largest reserved version');
const runner = await read('backend/tests/run-tests.sh');
assert(runner.includes('expected_migration_count='), 'Test runner must derive the expected migration count');

const project = await read('MojaSzafa.xcodeproj/project.pbxproj');
const ids = [...project.matchAll(/^\s*([0-9A-F]{24}) (?:\/\*.*?\*\/ )?= \{/gm)].map(m => m[1]);
const duplicates = ids.filter((id, i) => ids.indexOf(id) !== i);
assert.equal(duplicates.length, 0, `project.pbxproj: zduplikowane ID ${[...new Set(duplicates)].join(', ')}`);

console.log(`OK: ${versions.length} migrations through ${last} without collisions, ${ids.length} unikalnych ID w project.pbxproj`);
