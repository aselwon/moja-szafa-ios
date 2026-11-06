import { weatherContext } from '../weather/context.mjs';
import { recognitionSchema } from './recognition.mjs';

export const candidateLimit = 40;
const categories = recognitionSchema.properties.category.enum;
const invalid = code => { throw new Error(code); };
const identifier = value => typeof value === 'string' && value.length > 0 && value.length <= 128;

// Explicit allowlist: originals, thumbnails, storage URLs, ownership and purchase
// facts never enter the outfit prompt. Missing optional metadata stays unknown.
export function candidateMetadata(garment) {
  if (!identifier(garment?.id) || !categories.includes(garment.category)) invalid('candidate_invalid');
  const result = { id: garment.id, category: garment.category };
  for (const key of ['colors', 'pattern', 'seasons', 'formality']) {
    const value = garment[key];
    const rule = recognitionSchema.properties[key];
    if (value === undefined) continue;
    // The manual garment form/database allow free-text patterns (200 Unicode
    // scalars), while AI input uses a closed vocabulary. Keep custom text in
    // the wardrobe, but send unknown instead of rejecting the entire wardrobe
    // or forwarding arbitrary instructions to the model.
    if (key === 'pattern' && typeof value === 'string' && !rule.enum.includes(value) &&
        value.length <= 400 && [...value].length <= 200) {
      result.pattern = null;
      continue;
    }
    if (rule.enum ? !rule.enum.includes(value) : !Array.isArray(value) || value.length > rule.maxItems ||
        !value.every(entry => rule.items.enum.includes(entry))) invalid('candidate_invalid');
    result[key] = structuredClone(value);
  }
  return result;
}

export function eligibleGarments(input, ownerID) {
  if (!identifier(ownerID) || !Array.isArray(input?.garments)) invalid('input_invalid');
  const eligible = input.garments.filter(g => g && g.user_id === ownerID &&
    g.availability === 'available' && g.archived === false);
  const ids = new Set();
  for (const garment of eligible) {
    candidateMetadata(garment);
    if (ids.has(garment.id)) invalid('duplicate_candidate');
    ids.add(garment.id);
  }
  if (input.pinned_garment_id != null && !ids.has(input.pinned_garment_id)) invalid('pinned_garment_unavailable');
  return eligible;
}

// Preferences and occasion only rank; they cannot remove required categories or
// override ownership/availability. Occasion uses the domain's 1–5 formality scale.
export function selectCandidates(input, ownerID) {
  const eligible = eligibleGarments(input, ownerID);
  if (!eligible.length) invalid('no_available_garments');
  input = { ...input, count: input.count === undefined ? 3 : input.count };
  if (!Number.isInteger(input.count) || input.count < 1 || input.count > 10) invalid('input_invalid');
  const preferences = input.preferences ?? {};
  const preferredColors = preferences.colors ?? [];
  const preferredSeasons = preferences.seasons ?? [];
  for (const [key, values] of [['colors', preferredColors], ['seasons', preferredSeasons]]) {
    const rule = recognitionSchema.properties[key];
    if (!Array.isArray(values) || values.length > rule.maxItems || !values.every(v => rule.items.enum.includes(v))) invalid('preferences_invalid');
  }
  const formality = input.occasion?.formality ?? null;
  if (!recognitionSchema.properties.formality.enum.includes(formality)) invalid('occasion_invalid');
  const score = g => (Number.isInteger(g.preference_score) ? Math.max(-20, Math.min(20, g.preference_score)) : 0) + (g.colors ?? []).filter(c => preferredColors.includes(c)).length * 2 +
    (g.seasons ?? []).filter(s => preferredSeasons.includes(s)).length * 2 +
    (formality !== null && g.formality != null ? 5 - Math.abs(formality - g.formality) : 0);
  const ranked = [...eligible].sort((a, b) => score(b) - score(a) || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0));
  const selected = new Map();
  const pin = ranked.find(g => g.id === input.pinned_garment_id);
  if (pin) selected.set(pin.id, pin);
  const buckets = categories.map(category => ranked.filter(g => g.category === category && g.id !== pin?.id));
  // Round robin reserves coverage for rare shoes/dresses even in a top-heavy wardrobe.
  while (selected.size < candidateLimit && buckets.some(bucket => bucket.length)) {
    for (const bucket of buckets) {
      const garment = bucket.shift();
      if (garment) selected.set(garment.id, garment);
      if (selected.size === candidateLimit) break;
    }
  }
  const weather = weatherContext(input.weather);
  return { garments: [...selected.values()].map(candidateMetadata), count: input.count,
    preferences: { colors: [...preferredColors], seasons: [...preferredSeasons] },
    occasion: { formality }, ...(weather ? { weather } : {}), ...(pin ? { pinned_garment_id: pin.id } : {}) };
}
