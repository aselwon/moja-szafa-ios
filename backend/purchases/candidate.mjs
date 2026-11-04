import { candidateMetadata, selectCandidates } from '../ai/candidates.mjs';
import { validateOutfits } from '../ai/outfits.mjs';

// Domain boundary only: normalized image references must be resolved by an
// authenticated storage adapter. A candidate is never an owned garment.
export function createPurchaseCandidate({ id, ownerID, imageID, metadata, expiresAt }, now) {
  if (![id, ownerID, imageID].every(v => typeof v === 'string' && v.length > 0) ||
      !Number.isFinite(expiresAt) || expiresAt <= now) throw new Error('candidate_invalid');
  return { id, user_id: ownerID, image_id: imageID, metadata: candidateMetadata({ ...metadata, id }),
    expires_at: expiresAt, state: 'temporary' };
}

function authorize(candidate, ownerID, now) {
  if (candidate.user_id !== ownerID || candidate.state !== 'temporary' || candidate.expires_at <= now) {
    throw new Error('candidate_unavailable');
  }
}

export function purchaseFitInput(candidate, wardrobe, ownerID, now) {
  authorize(candidate, ownerID, now);
  if (wardrobe.some(g => g.id === candidate.id)) throw new Error('candidate_id_collision');
  const selected = selectCandidates({ garments: wardrobe, count: 3 }, ownerID);
  return { ...selected, purchase_candidate: structuredClone(candidate.metadata) };
}

// AI IDs refer exclusively to owned items. The hypothetical candidate contributes
// its category to completeness, but is kept separate in every returned proposal.
export function validatePurchaseFit(value, input) {
  const result = validateOutfits(value, input);
  return { ...result, outfits: result.outfits.map(outfit => {
    const combined = validateOutfits({ outfits: [{ garment_ids: [...outfit.garment_ids, input.purchase_candidate.id],
      rationale: outfit.rationale }], shortfall_reason: null }, {
      count: 1, garments: [...input.garments, input.purchase_candidate]
    }).outfits[0];
    return { ...outfit, complete: combined.complete, missing_categories: combined.missing_categories,
      purchase_candidate_id: input.purchase_candidate.id };
  }) };
}

// Adapter MUST atomically lock/re-read candidate, enforce owner and expiry, and
// deduplicate by candidate ID. Retry returns the original garment. No AI result
// can invoke this boundary: an explicit user confirmation is required.
export async function confirmPurchase({ candidateID, ownerID, confirmed, operationID }, repository) {
  if (confirmed !== true || !candidateID || !ownerID || !operationID) throw new Error('confirmation_required');
  return repository.confirmPurchaseAtomically({ candidateID, ownerID, operationID });
}
