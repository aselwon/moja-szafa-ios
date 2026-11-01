import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

const read = async path => JSON.parse(await readFile(new URL(path, import.meta.url), 'utf8'));
const tokens = await read('../design/tokens.json');
const catalog = await read('../design/Localizable.xcstrings');
const luminance = hex => {
  const rgb = hex.slice(1).match(/../g).map(v => parseInt(v, 16) / 255)
    .map(v => v <= 0.04045 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4);
  return rgb[0] * 0.2126 + rgb[1] * 0.7152 + rgb[2] * 0.0722;
};
for (const name of ['background', 'surface', 'primaryText', 'secondaryText', 'accent', 'onAccent', 'border', 'danger', 'warning', 'success']) {
  for (const mode of ['light', 'dark']) assert.match(tokens.colors[name]?.[mode] ?? '', /^#[0-9A-F]{6}$/, `${name}/${mode}`);
}
// Required pairs live here too: removing a pair from the asset cannot bypass a check.
const pairs = ['primaryText', 'secondaryText', 'accent', 'danger', 'warning', 'success']
  .flatMap(f => ['background', 'surface'].map(b => [f, b, 4.5]));
pairs.push(['onAccent', 'accent', 4.5], ['border', 'background', 3], ['border', 'surface', 3]);
let minimumText = Infinity;
for (const [f, b, minimum] of pairs) {
  assert(tokens.contrastPairs.some(p => p.foreground === f && p.background === b && p.minimum >= minimum), `Brak pary ${f}/${b}`);
  for (const mode of ['light', 'dark']) {
    const a = luminance(tokens.colors[f][mode]), z = luminance(tokens.colors[b][mode]);
    const ratio = (Math.max(a, z) + 0.05) / (Math.min(a, z) + 0.05);
    assert(ratio >= minimum, `${f}/${b}/${mode}: ${ratio.toFixed(2)} < ${minimum}`);
    if (minimum === 4.5) minimumText = Math.min(minimumText, ratio);
  }
}
assert(tokens.minimumTouchTarget >= 44);
for (const role of ['screenTitle', 'sectionTitle', 'cardTitle', 'body', 'action', 'metadata', 'caption']) {
  assert(['largeTitle', 'title2', 'headline', 'body', 'subheadline', 'caption'].includes(tokens.typography[role]?.style), role);
}
assert.equal(catalog.version, '1.0');
assert.equal(catalog.sourceLanguage, 'pl');
const placeholders = value => (value.match(/%(?:\d+\$)?(?:lld|@)/g) ?? []).sort();
function unit(node, context) {
  assert.equal(node?.stringUnit?.state, 'translated', context);
  const value = node.stringUnit.value;
  assert.equal(typeof value, 'string', context);
  assert(value.trim().length > 0, context);
  assert(!/%/.test(value.replace(/%%|%(?:\d+\$)?(?:lld|@)/g, '')), `Nieobsługiwany placeholder: ${context}`);
  return placeholders(value);
}
for (const key of ['tab.today', 'tab.wardrobe', 'tab.outfits', 'tab.statistics', 'common.save', 'common.cancel', 'account.deleteWarning', 'wardrobe.count', 'wear.days', 'sync.lastUpdated']) assert(catalog.strings[key], key);
for (const [key, entry] of Object.entries(catalog.strings)) {
  assert(entry.comment?.trim(), `Brak kontekstu: ${key}`);
  const signatures = [];
  for (const locale of ['pl', 'en']) {
    const node = entry.localizations?.[locale];
    assert(node, `${key}/${locale}`);
    if (node.variations) {
      const forms = node.variations.plural;
      assert(forms, `${key}: nieznany rodzaj wariantów`);
      for (const form of locale === 'pl' ? ['one', 'few', 'many', 'other'] : ['one', 'other']) assert(forms[form], `${key}/${locale}/${form}`);
      for (const [form, variant] of Object.entries(forms)) signatures.push(unit(variant, `${key}/${locale}/${form}`));
    } else signatures.push(unit(node, `${key}/${locale}`));
  }
  for (const signature of signatures) assert.deepEqual(signature, signatures[0], `Niezgodne argumenty: ${key}`);
  if (['wardrobe.count', 'wear.days'].includes(key)) {
    assert(entry.localizations.pl.variations?.plural && entry.localizations.en.variations?.plural, `Wymagany plural: ${key}`);
    assert.deepEqual(signatures[0], ['%lld']);
  }
  if (key === 'sync.lastUpdated') assert.deepEqual(signatures[0], ['%@']);
}
console.log(`OK: T003, ${Object.keys(catalog.strings).length} kluczy PL/EN, kontrast tekstu min. ${minimumText.toFixed(2)}:1, oba motywy`);
