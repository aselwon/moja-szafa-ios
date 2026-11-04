// Provider contract. Completeness is derived by the server, never trusted to AI.
export const outfitSchema = {
  type: 'object', additionalProperties: false, required: ['outfits', 'shortfall_reason'],
  properties: {
    outfits: { type: 'array', maxItems: 10, items: {
      type: 'object', additionalProperties: false, required: ['garment_ids', 'rationale'],
      properties: {
        garment_ids: { type: 'array', minItems: 1, maxItems: 40, uniqueItems: true,
          items: { type: 'string', minLength: 1, maxLength: 128 } },
        rationale: { type: 'string', minLength: 1, maxLength: 1000 }
      }
    } },
    shortfall_reason: { type: ['string', 'null'], minLength: 1, maxLength: 1000 }
  }
};
const object = v => v !== null && typeof v === 'object' && !Array.isArray(v);
const text = v => typeof v === 'string' && v.trim().length > 0 && v.length <= 1000;
const exact = (v, keys) => object(v) && Object.keys(v).length === keys.length && keys.every(k => Object.hasOwn(v, k));

export function validateOutfits(value, input) {
  const invalid = () => { throw new Error('outfits_invalid'); };
  if (!exact(value, ['outfits', 'shortfall_reason']) || !Array.isArray(value.outfits) ||
      value.outfits.length > input.count || value.outfits.length > 10 ||
      !(value.shortfall_reason === null || text(value.shortfall_reason))) invalid();
  if (value.outfits.length < input.count && !text(value.shortfall_reason)) invalid();
  const garments = new Map(input.garments.map(g => [g.id, g]));
  const seen = new Set();
  const outfits = [];
  for (const outfit of value.outfits) {
    if (!exact(outfit, ['garment_ids', 'rationale']) || !text(outfit.rationale) ||
        !Array.isArray(outfit.garment_ids) || !outfit.garment_ids.length || outfit.garment_ids.length > 40 ||
        new Set(outfit.garment_ids).size !== outfit.garment_ids.length ||
        outfit.garment_ids.some(id => !garments.has(id)) ||
        (input.pinned_garment_id && !outfit.garment_ids.includes(input.pinned_garment_id))) invalid();
    const key = JSON.stringify([...outfit.garment_ids].sort());
    if (seen.has(key)) continue;
    seen.add(key);
    const categories = new Set(outfit.garment_ids.map(id => garments.get(id).category));
    const missing = [];
    if (!categories.has('dress') && !categories.has('jumpsuit')) {
      if (!categories.has('top')) missing.push('top');
      if (!categories.has('bottom')) missing.push('bottom');
    }
    if (!categories.has('shoes')) missing.push('shoes');
    outfits.push({ ...structuredClone(outfit), complete: missing.length === 0, missing_categories: missing });
  }
  return { outfits, shortfall_reason: outfits.length < input.count
    ? value.shortfall_reason ?? 'Duplicate outfit proposals were removed; fewer distinct outfits are available.' : null };
}
