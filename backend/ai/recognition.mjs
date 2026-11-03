// Versioned provider contract; additional fields (including purchase facts) are rejected.
export const recognitionSchema = {
  $schema: 'https://json-schema.org/draft/2020-12/schema',
  type: 'object', additionalProperties: false,
  required: ['category', 'colors', 'pattern', 'seasons', 'formality', 'confidence', 'multiple_items'],
  properties: {
    category: { enum: ['top', 'bottom', 'shoes', 'dress', 'jumpsuit', 'outerwear', 'accessory', 'other'] },
    colors: { type: 'array', uniqueItems: true, maxItems: 13, items: { enum: ['black', 'white', 'gray', 'beige', 'brown', 'red', 'orange', 'yellow', 'green', 'blue', 'purple', 'pink', 'other'] } },
    pattern: { enum: [null, 'plain', 'stripes', 'checks', 'dots', 'floral', 'graphic', 'animal', 'other'] },
    seasons: { type: 'array', uniqueItems: true, maxItems: 4, items: { enum: ['spring', 'summer', 'autumn', 'winter'] } },
    formality: { enum: [null, 1, 2, 3, 4, 5] },
    confidence: { type: 'number', minimum: 0, maximum: 1 },
    multiple_items: { type: 'boolean' }
  }
};

export const recognitionReviewThreshold = 0.8;

// Explicit validator for this closed, flat schema; no coercion or silent filtering.
export function validateRecognition(value) {
  const invalid = () => { throw new Error('recognition_invalid'); };
  if (!value || typeof value !== 'object' || Array.isArray(value) ||
      Object.keys(value).length !== recognitionSchema.required.length ||
      !recognitionSchema.required.every(key => Object.hasOwn(value, key))) invalid();
  for (const [key, rule] of Object.entries(recognitionSchema.properties)) {
    const item = value[key];
    if (rule.enum && !rule.enum.includes(item)) invalid();
    if (rule.type === 'array' && (!Array.isArray(item) || item.length > rule.maxItems ||
        new Set(item).size !== item.length || !item.every(entry => rule.items.enum.includes(entry)))) invalid();
    if (rule.type === 'number' && (typeof item !== 'number' || !Number.isFinite(item) || item < 0 || item > 1)) invalid();
    if (rule.type === 'boolean' && typeof item !== 'boolean') invalid();
  }
  return structuredClone(value);
}

export function recognitionDraft(value) {
  const metadata = validateRecognition(value);
  return { schema_version: 'garment-recognition-v1', state: 'draft', metadata,
    requires_correction: metadata.confidence < recognitionReviewThreshold || metadata.category === 'other' || metadata.multiple_items };
}
