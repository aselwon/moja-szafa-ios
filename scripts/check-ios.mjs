import assert from 'node:assert/strict';
import { readFile, readdir, access } from 'node:fs/promises';

const root = new URL('../', import.meta.url);
const read = path => readFile(new URL(path, root), 'utf8');
const project = await read('MojaSzafa.xcodeproj/project.pbxproj');
const scheme = await read('MojaSzafa.xcodeproj/xcshareddata/xcschemes/MojaSzafa.xcscheme');
// Structural checks only; Xcode must compile Swift, assets and the String Catalog.
for (const match of project.matchAll(/path = "([^"]+)"; sourceTree = SOURCE_ROOT;/g)) {
  await access(new URL(match[1], root));
}
async function checkSources(directory) {
  for (const entry of await readdir(new URL(directory, root), { withFileTypes: true })) {
    const path = `${directory}/${entry.name}`;
    if (entry.isDirectory()) await checkSources(path);
    else if (entry.name.endsWith('.swift')) assert(project.includes(`path = "${path}"`), `Source absent from Xcode: ${path}`);
  }
}
await checkSources('MojaSzafa');
await checkSources('MojaSzafaTests');
assert(project.includes('path = "design/Localizable.xcstrings"'));
assert(project.includes('developmentRegion = pl;'));
assert(project.includes('knownRegions = (pl,en,Base);'));
assert(scheme.includes('BlueprintName="MojaSzafaTests"'));
assert(scheme.includes('skipped="NO"'));
assert(scheme.includes('ArchiveAction buildConfiguration="Release"'));
const tokens = JSON.parse(await read('design/tokens.json'));
for (const [name, modes] of Object.entries(tokens.colors)) {
  const asset = JSON.parse(await read(`MojaSzafa/Resources/Assets.xcassets/${name}.colorset/Contents.json`));
  for (const [mode, hex] of Object.entries(modes)) {
    const entry = asset.colors.find(c => mode === 'dark'
      ? c.appearances?.some(a => a.appearance === 'luminosity' && a.value === 'dark')
      : !c.appearances);
    assert(entry, `${name}/${mode}`);
    for (const [index, channel] of ['red', 'green', 'blue'].entries()) {
      assert(Math.abs(Number(entry.color.components[channel]) - parseInt(hex.slice(1 + index * 2, 3 + index * 2), 16) / 255) < 1e-7, `${name}/${mode}/${channel}`);
    }
    assert.equal(Number(entry.color.components.alpha), 1);
  }
}
console.log('OK: T005 source references, shared test scheme and T003 asset parity (not an Xcode build)');
