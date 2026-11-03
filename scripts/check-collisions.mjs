import assert from 'node:assert/strict';
import { readFile, readdir } from 'node:fs/promises';

// Parallel tasks collide on migration numbers and Xcode object IDs; fail fast instead of in CI.
const root = new URL('../', import.meta.url);
const read = path => readFile(new URL(path, root), 'utf8');

const versions = (await readdir(new URL('backend/migrations/', root))).filter(n => n.endsWith('.sql')).map(n => n.slice(0, 3)).sort();
versions.forEach((v, i) => assert.equal(v, String(i + 1).padStart(3, '0'), `Migracje: duplikat lub luka przy ${v} (oczekiwano kolejnego wolnego numeru)`));
const last = versions.at(-1);
const migrate = await read('backend/migrate.sh');
assert(migrate.includes(`target=\${2:-${last}}`), `backend/migrate.sh: domyslny target musi byc ${last}`);
assert(migrate.includes(`|${last}]}`), `backend/migrate.sh: brak ${last} w liscie Usage`);
const accepted = migrate.match(/=~ (\^\(.+?\)\$) \]\]/);
assert(accepted && new RegExp(accepted[1]).test(last), `backend/migrate.sh: regex targetu nie przyjmuje ${last}`);
const schema = await read('backend/tests/schema.sql');
assert(schema.includes(`count(*) = ${Number(last)} FROM migration_meta.versions`), `backend/tests/schema.sql: liczba migracji musi byc ${Number(last)}`);

const project = await read('MojaSzafa.xcodeproj/project.pbxproj');
const ids = [...project.matchAll(/^\s*([0-9A-F]{24}) (?:\/\*.*?\*\/ )?= \{/gm)].map(m => m[1]);
const duplicates = ids.filter((id, i) => ids.indexOf(id) !== i);
assert.equal(duplicates.length, 0, `project.pbxproj: zduplikowane ID ${[...new Set(duplicates)].join(', ')}`);

console.log(`OK: migracje 001-${last} bez kolizji, ${ids.length} unikalnych ID w project.pbxproj`);
