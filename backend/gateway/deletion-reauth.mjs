import { randomBytes, createHash } from 'node:crypto';
import { GatewayError } from './managed-auth.mjs';

const uuid = value => typeof value === 'string' && /^[a-f0-9]{8}(-[a-f0-9]{4}){3}-[a-f0-9]{12}$/i.test(value);
export class DeletionReauthentication {
  constructor({ auth, store }) { Object.assign(this, { auth, store }); }
  async start(principal) {
    const challenge = await this.store.deletionReauthentication('start', principal);
    if (!challenge?.id || challenge.email !== principal.email) throw new GatewayError('deletion_unavailable', 503);
    const receiptToken = randomBytes(32).toString('base64url');
    const hash = createHash('sha256').update(receiptToken).digest('hex');
    if (!await this.store.createDeletionReceipt(principal, challenge.id, hash)) throw new GatewayError('deletion_unavailable', 503);
    await this.auth.sendOTP(challenge.email);
    return { id: challenge.id, method: 'email', nonce: null, state: null, receiptToken };
  }
  async status(principal, input) {
    if (input?.receipt_token !== undefined) {
      if (Object.keys(input).sort().join(',') !== 'challenge_id,operation_id,receipt_token' ||
          !uuid(input.operation_id) || !uuid(input.challenge_id) || typeof input.receipt_token !== 'string' ||
          !/^[A-Za-z0-9_-]{43}$/.test(input.receipt_token)) throw new GatewayError('invalid_request', 400);
      const hash = createHash('sha256').update(input.receipt_token).digest('hex');
      return { accepted: await this.store.deletionReceiptStatus(input.challenge_id, input.operation_id, hash) };
    }
    if (!principal) throw new GatewayError('unauthorized', 401);
    if (!input || Object.keys(input).sort().join(',') !== 'challenge_id,operation_id' ||
        !uuid(input.operation_id) || !uuid(input.challenge_id)) throw new GatewayError('invalid_request', 400);
    const result = await this.store.deletionReauthentication('receipt', principal,
      { challenge: input.challenge_id, operation: input.operation_id });
    return { accepted: Boolean(result?.receipt) };
  }
  async confirm(principal, input) {
    if (!input || Object.keys(input).sort().join(',') !== 'operation_id,proof' || !uuid(input.operation_id) ||
      !input.proof || Object.keys(input.proof).sort().join(',') !== 'challenge_id,code' ||
      !uuid(input.proof.challenge_id) || typeof input.proof.code !== 'string' || !/^\d{4,10}$/.test(input.proof.code)) {
      throw new GatewayError('invalid_request', 400);
    }
    const context = { challenge: input.proof.challenge_id, operation: input.operation_id };
    const attempt = await this.store.deletionReauthentication('attempt', principal, context);
    if (attempt?.receipt) return attempt.receipt;
    if (!attempt?.email || attempt.email !== principal.email) throw new GatewayError('reauthentication_required', 403);
    let fresh;
    try {
      // No caller-supplied email, provider session or owner is accepted as proof.
      fresh = await this.auth.verifyOTP(attempt.email, input.proof.code);
      if (fresh.owner !== principal.owner || fresh.email !== attempt.email || fresh.sessionID === principal.sessionID) {
        throw new GatewayError('reauthentication_required', 403);
      }
      const accepted = await this.store.deletionReauthentication('accept', principal, { ...context, freshSession: fresh.sessionID });
      if (!accepted?.receipt) throw new GatewayError('reauthentication_required', 403);
      return accepted.receipt;
    } finally {
      if (fresh?.token) await this.auth.logout(fresh.token).catch(() => {});
    }
  }
}
