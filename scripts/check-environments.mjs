import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
const read = path => readFile(new URL(`../${path}`, import.meta.url), 'utf8');
const project = await read('MojaSzafa.xcodeproj/project.pbxproj');
assert(project.includes('buildPhases = (000000000000000000000046,'), 'Environment guard must run before compilation');
for (const [configuration, environment, suffix, file, reference] of [
  ['Debug', 'dev', '.dev', 'Dev', '43'],
  ['Staging', 'staging', '.staging', 'Staging', '44'],
  ['Release', 'prod', '', 'Production', '45'],
]) {
  const config = await read(`Configuration/${file}.xcconfig`);
  const settings = Object.fromEntries([...config.matchAll(/^(\w+)[ \t]*=[ \t]*(.*?)[ \t]*$/gm)].map(m => [m[1], m[2]]));
  assert.equal(settings.APP_ENVIRONMENT, environment);
  assert.equal(settings.PRODUCT_BUNDLE_IDENTIFIER, `pl.mojaszafa.app${suffix}`);
  assert.equal(settings.BACKEND_BASE_URL, '');
  assert(project.includes(`baseConfigurationReference = ${'0'.repeat(22)}${reference}; name = ${configuration};`));
  const env = { ...settings, CONFIGURATION: configuration, CODE_SIGNING_ALLOWED: 'NO',
    INFOPLIST_KEY_AppEnvironment: environment, INFOPLIST_KEY_BackendBaseURL: '' };
  const run = async overrides => {
    try {
      await promisify(execFile)('/bin/bash', ['scripts/validate-build-environment.sh'], { env: { ...env, ...overrides } });
      return 0;
    } catch (error) {
      if (typeof error.code !== 'number') throw error;
      return error.code;
    }
  };
  assert.equal(await run({}), 0, `${configuration}: valid config rejected`);
  for (const override of [
    { APP_ENVIRONMENT: 'wrong' }, { PRODUCT_BUNDLE_IDENTIFIER: 'wrong' },
    { INFOPLIST_KEY_AppEnvironment: 'wrong' }, { CODE_SIGN_STYLE: 'wrong' },
    { BACKEND_BASE_URL: 'https://staging.invalid' }, { INFOPLIST_KEY_BackendBaseURL: 'https://staging.invalid' },
    { CONFIGURATION: 'Unknown' },
  ]) assert.equal(await run(override), 1, `${configuration}: unsafe override accepted`);
  if (configuration === 'Release') {
    assert.equal(await run({ CODE_SIGNING_ALLOWED: 'YES' }), 1);
    assert.equal(await run({ CODE_SIGNING_ALLOWED: 'YES', DEVELOPMENT_TEAM: 'example' }), 1);
    assert.equal(await run({ CODE_SIGNING_ALLOWED: 'YES', DEVELOPMENT_TEAM: 'example', PROVISIONING_PROFILE_SPECIFIER: 'example' }), 0);
  }
}
for (const scheme of ['MojaSzafa', 'MojaSzafa-Staging']) {
  const xml = await read(`MojaSzafa.xcodeproj/xcshareddata/xcschemes/${scheme}.xcscheme`);
  assert(xml.includes('ArchiveAction buildConfiguration="Release"'));
  if (scheme.endsWith('Staging')) assert(xml.includes('TestAction buildConfiguration="Staging"'));
}
console.log('OK: T006 environment mappings, signing policy and unsafe-override rejection');
