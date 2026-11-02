// Deployment supplies real auth/Apple/storage adapters. No default success mocks.
// verifyDeletionProof must verify a short-lived challenge bound to the owner,
// operation UUID and deletion purpose, rate-limit attempts, and permit exact replay.
export async function requestDeletion({ auth, store }, bearer, request) {
  if (!request || !['operationID', 'challengeID', 'code'].every(k => typeof request[k] === 'string' && request[k]) ||
      Object.keys(request).some(k => !['operationID', 'challengeID', 'code'].includes(k))) {
    throw new Error('invalid_request');
  }
  const owner = await auth.verifyDeletionProof(bearer, request);
  if (!owner) throw new Error('reauthorization_required');
  // Commit the durable fence before any external side effect. Workers invalidate
  // sessions even if this HTTP response is lost. Gateway must deny tombstoned users.
  const jobID = await store.enqueue(owner, request.operationID);
  return { jobID, status: 'queued' };
}

export async function runDeletionOnce(store, adapters) {
  const job = await store.claim();
  if (!job) return false;
  try {
    // Every adapter is idempotent with job.id. Each must bound its duration below
    // the lease; absence of credentials or unknown outcomes must throw, not succeed.
    await adapters.revokeSessions(job.owner, job.id);
    await adapters.revokeAppleTokens(job.owner, job.id);
    await adapters.removeImages(job.owner, job.id);
    await adapters.deleteAuthIdentity(job.owner, job.id);
  } catch {
    await store.finish(job, false);
    return true;
  }
  // Lost commit response is recovered via lease expiry, never reported as success.
  await store.finish(job, true);
  return true;
}
