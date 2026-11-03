// Plug into the T013 gateway after its signature/audience/issuer verification.
// All identity and token storage belong to the auth adapter, never request JSON.
export async function requestDeletion({ body, bearer }, { auth, store, now = () => Date.now() }) {
  const uuid = value => typeof value === 'string' && /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i.test(value);
  if (!body || !uuid(body.operationID) || Object.keys(body).some(k => !['operationID', 'appleAuthorizationCode'].includes(k)) ||
      (body.appleAuthorizationCode !== undefined && (typeof body.appleAuthorizationCode !== 'string' || body.appleAuthorizationCode.length > 4096))) {
    throw new Error('validation_failed');
  }
  // Signature/issuer/audience/expiry must still be valid for receipt-only access;
  // revoked sessions can recover ONLY their existing operation's receipt.
  const identity = await auth.verifySignature(bearer);
  if (!uuid(identity?.userID)) throw new Error('unauthorized');
  const command = { owner: identity.userID, operationID: body.operationID };
  const receipt = await store.command({ ...command, action: 'receipt' });
  if (receipt) return receipt;
  await auth.requireActiveSession(identity);
  const age = now() / 1000 - identity.authTime;
  if (!Number.isFinite(age) || age < 0 || age > 300) throw new Error('reauthentication_required');
  // Escrow revocable Apple credentials for ALL linked Apple identities before
  // session invalidation. Code exchange must bind Apple's subject to this user.
  // Email reauth does not waive revocation of a linked Apple identity.
  await auth.prepareAppleRevocation(identity, body.appleAuthorizationCode);
  return store.command({ ...command, action: 'begin' });
}
