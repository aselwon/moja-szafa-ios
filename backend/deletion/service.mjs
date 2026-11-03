import { execFile } from 'node:child_process';
const uuid = value => typeof value === 'string' && /^[a-f0-9]{8}(-[a-f0-9]{4}){3}-[a-f0-9]{12}$/.test(value);

export class AccountDeletion {
  constructor({ store, identity, storage, backups, timeoutMs = 240_000 }) {
    if (!Number.isInteger(timeoutMs) || timeoutMs < 1 || timeoutMs > 240_000) throw new Error('invalid_timeout');
    Object.assign(this, { store, identity, storage, backups, timeoutMs });
  }
  async challenge(owner) {
    if (!uuid(owner)) throw new Error('unauthorized');
    // Adapter sends OTP ONLY to a verified linked address or creates an Apple
    // nonce/state challenge. Purpose=delete, owner-bound, five minute expiry,
    // rate limited. Never accepts an arbitrary email/account from the client.
    return this.identity.startDeletionChallenge(owner);
  }
  async request(owner, id, proof) {
    if (!uuid(owner) || !uuid(id)) throw new Error('invalid_request');
    // Verify signature/issuer/audience/nonce and SAME subject for Apple; exchange
    // authorizationCode and durably retain revocable token in the secret vault.
    // OTP must be challenge-bound. Replay is allowed ONLY for this operation ID.
    if (!await this.identity.verifyDeletionChallenge(owner, id, proof)) throw new Error('reauthentication_required');
    const result = await this.store.call('request', { owner, id });
    if (!result) throw new Error('account_unavailable');
    return result;
  }
  async tick() {
    const job = await this.store.call('claim', {});
    if (!job) return false;
    const args = { id: job.id, fence: job.fence };
    const controller = new AbortController();
    let timer;
    const step = async action => {
      controller.signal.throwIfAborted();
      await action({ signal: controller.signal });
      controller.signal.throwIfAborted();
    };
    const cleanup = async () => {
      // The independent journal must precede removal of any authentication data.
      await step(options => this.backups.recordDeletion(job.owner, job.id, options));
      await step(options => this.identity.revokeAllSessions(job.owner, options));
      await step(options => this.identity.revokeAppleTokens(job.owner, options));
      await step(options => this.storage.eraseAccount(job.owner, options));
      await step(options => this.identity.deleteAccount(job.owner, options));
    };
    try {
      await Promise.race([cleanup(), new Promise((_, reject) => {
        timer = setTimeout(() => {
          controller.abort();
          reject(new Error('deletion_timeout'));
        }, this.timeoutMs);
      })]);
      if (!await this.store.call('finish', args)) throw new Error('lease_lost');
    } catch {
      await this.store.call('retry', args);
    } finally {
      clearTimeout(timer);
      controller.abort();
    }
    return true;
  }
}

export function postgresDeletion() {
  return { call(action, args) {
    const input = JSON.stringify({ action, ...args });
    return new Promise((resolve, reject) => {
      const child = execFile('psql', ['-XAt', '-v', 'ON_ERROR_STOP=1'], { timeout: 15000, maxBuffer: 1024 * 1024 },
        (error, stdout) => {
          if (error) return reject(new Error('deletion_store_unavailable'));
          try { resolve(JSON.parse(stdout.trim())); } catch { reject(new Error('deletion_store_unavailable')); }
        });
      child.stdin.end(`SELECT app.deletion_command(convert_from(decode('${Buffer.from(input).toString('hex')}', 'hex'),'UTF8')::jsonb);`);
    });
  } };
}
