import assert from 'node:assert/strict';
import { promisify } from 'node:util';
import { execFile } from 'node:child_process';
import { readFile } from 'node:fs/promises';

// Offline, dependency-free working-tree scan. Report locations/rule names only,
// never matched values. This is pattern detection, not proof of no credentials.
const rules = [
  ['private-key', /-----BEGIN (?:[A-Z0-9]+ )*PRIVATE KEY-----/],
  ['aws-access-key', /\b(?:AKIA|ASIA)[A-Z0-9]{16}\b/],
  ['github-token', /\b(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})\b/],
  ['provider-key', /\b(?:sk-(?:proj-|live_|test_)?[A-Za-z0-9_-]{20,}|xox[baprs]-[A-Za-z0-9-]{20,})\b/],
  ['credential-url', /[a-z][a-z0-9+.-]*:\/\/[^\s/:]+:[^\s/@]+@/i],
  ['assigned-secret', /\b(?:api[_-]?key|client[_-]?secret|password|access[_-]?token)\s*[:=]\s*["'][A-Za-z0-9+/=_-]{16,}["']/i],
];
export function violations(path, content) {
  const found = rules.filter(([, pattern]) => pattern.test(content)).map(([name]) => name);
  if (/(?:^|\/)\.env(?:\.|$)|\.(?:p8|p12|pem|key|mobileprovision)$|\.local\.xcconfig$/i.test(path)) found.push('credential-file');
  return found;
}
// Synthetic values are assembled so the scanner does not need fixture exclusions.
for (const [path, sample, rule] of [
  ['a', '-----BEGIN ' + 'PRIVATE KEY-----', 'private-key'],
  ['a', 'AKIA' + 'A'.repeat(16), 'aws-access-key'],
  ['a', 'ghp_' + 'a'.repeat(30), 'github-token'],
  ['a', 'sk-proj-' + 'a'.repeat(30), 'provider-key'],
  ['a', 'postgres://' + 'user:pass@host', 'credential-url'],
  ['a', 'api_key = "' + 'a'.repeat(24) + '"', 'assigned-secret'],
  ['.env.local', '', 'credential-file'],
  ['profile.mobileprovision', '', 'credential-file'],
]) assert(violations(path, sample).includes(rule), `Secret rule regression: ${rule}`);
assert.deepEqual(violations('Configuration/Production.xcconfig', 'DEVELOPMENT_TEAM =\nBACKEND_BASE_URL ='), []);
const paths = (await promisify(execFile)('git', ['ls-files', '-z', '--cached', '--others', '--exclude-standard'], { encoding: 'utf8' })).stdout.split('\0').filter(Boolean);
let failures = 0;
for (const path of new Set(paths)) {
  let data;
  try { data = await readFile(path); } catch (error) { if (error.code === 'ENOENT') continue; throw error; }
  for (const rule of violations(path, data.toString('utf8'))) {
    console.error(`Secret scan: ${path}: ${rule}`);
    failures++;
  }
}
assert.equal(failures, 0, 'Secret scan failed; remove credentials without printing them');
console.log('OK: offline secret scan and synthetic detection tests (current tracked/unignored files)');
