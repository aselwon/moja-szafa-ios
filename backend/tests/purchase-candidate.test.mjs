import assert from 'node:assert/strict';
import { createPurchaseCandidate, purchaseFitInput, validatePurchaseFit, confirmPurchase } from '../purchases/candidate.mjs';
const candidate = createPurchaseCandidate({ id: 'candidate', ownerID: 'owner', imageID: 'private-image', metadata: { category: 'dress' }, expiresAt: 100 }, 0);
const wardrobe = [{ id: 'shoes', user_id: 'owner', category: 'shoes', availability: 'available', archived: false }];
const input = purchaseFitInput(candidate, wardrobe, 'owner', 1);
const answer = { outfits: [{ garment_ids: ['shoes'], rationale: 'Matching shoes' }], shortfall_reason: 'One combination available' };
assert.equal(validatePurchaseFit(answer, input).outfits[0].complete, true);
assert.deepEqual(validatePurchaseFit(answer, input).outfits[0].garment_ids, ['shoes']);
assert.equal(wardrobe.length, 1);
for (const id of ['candidate', 'foreign', 'unknown']) {
  assert.throws(() => validatePurchaseFit({ ...answer, outfits: [{ garment_ids: [id], rationale: 'Invalid' }] }, input));
}
assert.throws(() => purchaseFitInput(candidate, wardrobe, 'other', 1));
assert.throws(() => purchaseFitInput(candidate, wardrobe, 'owner', 100));
assert.throws(() => validatePurchaseFit({ ...answer, predicted_cpw: 1 }, input));
let calls = 0;
const repository = { async confirmPurchaseAtomically() { calls++; return 'garment'; } };
await assert.rejects(confirmPurchase({ candidateID: 'candidate', ownerID: 'owner', operationID: 'op', confirmed: false }, repository));
assert.equal(calls, 0);
assert.equal(await confirmPurchase({ candidateID: 'candidate', ownerID: 'owner', operationID: 'op', confirmed: true }, repository), 'garment');
assert.equal(calls, 1);
console.log('OK: purchase candidate domain boundaries');
