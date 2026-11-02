// Gateway composition contract. No default/mock identity or Apple adapter.
// Proof verification must be purpose-bound, <=5 minutes old, nonce/state checked,
// and bound to session.subject. The adapter stores Apple revocation credentials
// durably BEFORE acceptance; no raw credentials belong in the deletion ledger.
export async function requestDeletion({ identity, store }, session, request) {
  if (!session?.subject || !request?.operationID || !request?.proof) throw new Error('reauthentication_required');
  const verified = await identity.reauthenticate(session, request.proof, request.operationID);
  if (verified.subject !== session.subject || verified.purpose !== 'account_deletion' ||
      !Number.isFinite(verified.authenticatedAt) || Date.now() - verified.authenticatedAt > 300_000 ||
      verified.authenticatedAt > Date.now()) {
    throw new Error('reauthentication_required');
  }
  // Replays for a deleted subject must authenticate proof against the durable
  // identity vault without re-creating a profile or issuing a new login session.
  const jobID = await store.begin(session.subject, request.operationID);
  return { jobID, status: 'queued' };
}

export async function runDeletionOnce({ store, identity, storage }) {
  const job = await store.claim();
  if (!job) return false;
  // Every operation MUST be idempotent, including an already revoked/deleted
  // identity. A crash/lost response leaves the lease for bounded durable retry.
  // Adapters must time out within the five-minute lease and never log tokens.
  await identity.revokeSessions(job.owner);
  await identity.revokeApple(job.owner); // no-op only for proven non-Apple account
  for (const id of job.images) await storage.remove(id);
  await identity.deleteUser(job.owner);
  await store.finish(job.id, job.lease);
  return true;
}
