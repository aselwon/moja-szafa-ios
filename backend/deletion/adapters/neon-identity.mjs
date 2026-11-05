import { constants } from 'node:fs';
import { open } from 'node:fs/promises';

const uuid = value => typeof value === 'string' && /^[a-f0-9]{8}(-[a-f0-9]{4}){3}-[a-f0-9]{12}$/.test(value);
const identifier = value => typeof value === 'string' && /^[a-z0-9]+(?:-[a-z0-9]+)+$/.test(value);

// The deployment supplies a project-scoped Editor API key, never a client
// session or a branch storage credential. This adapter does not provision keys.
export async function privateManagementKey(path) {
  const file = await open(path, constants.O_RDONLY | constants.O_NOFOLLOW);
  try {
    const info = await file.stat();
    if (!info.isFile() || (info.mode & 0o077) !== 0 || info.size < 1 || info.size > 4096) throw new Error('management_key_unavailable');
    const key = (await file.readFile('utf8')).trim();
    if (!/^[\x21-\x7e]{16,4096}$/.test(key)) throw new Error('management_key_unavailable');
    return key;
  } finally { await file.close(); }
}

export function neonIdentity({ project, branch, key, store, fetchImpl = fetch, timeoutMs = 15_000 }) {
  if (!identifier(project) || !identifier(branch) || typeof key !== 'string' || !/^[\x21-\x7e]{16,4096}$/.test(key)) throw new Error('identity_configuration_required');
  if (!Number.isInteger(timeoutMs) || timeoutMs < 1 || timeoutMs > 30_000) throw new Error('identity_configuration_required');
  for (const method of ['assertLease', 'revokeSessions', 'hasAppleIdentity', 'approveDeletion', 'identityAbsent']) {
    if (typeof store?.[method] !== 'function') throw new Error('identity_store_required');
  }
  async function checked(owner, options) {
    if (!uuid(owner) || !uuid(options?.job) || !uuid(options?.fence) || !options.signal) throw new Error('invalid_deletion_context');
    options.signal.throwIfAborted();
    if (!await store.assertLease(owner, options)) throw new Error('lease_lost');
  }
  return {
    async revokeAllSessions(owner, options) {
      await checked(owner, options);
      await store.revokeSessions(owner, options);
    },
    async revokeAppleTokens(owner, options) {
      await checked(owner, options);
      // A linked Apple identity needs a real revocation adapter and credentials.
      // Never silently delete that identity and pretend Apple was notified.
      if (await store.hasAppleIdentity(owner, options)) throw new Error('apple_revocation_unavailable');
    },
    async deleteAccount(owner, options) {
      await checked(owner, options);
      if (await store.identityAbsent(owner, options)) return;
      await store.approveDeletion(owner, options);
      options.signal.throwIfAborted();
      let response;
      try {
        response = await fetchImpl(`https://console.neon.tech/api/v2/projects/${project}/branches/${branch}/auth/users/${owner}`, {
          method: 'DELETE', redirect: 'error', headers: { Authorization: `Bearer ${key}` },
          signal: AbortSignal.any([options.signal, AbortSignal.timeout(timeoutMs)])
        });
        // No provider body is logged or retained: it can contain personal data.
        await response.body?.cancel();
      } catch { /* A dropped response is ambiguous; the database is authoritative. */ }
      await checked(owner, options);
      if (!await store.identityAbsent(owner, options)) throw new Error('identity_deletion_unconfirmed');
    }
  };
}
