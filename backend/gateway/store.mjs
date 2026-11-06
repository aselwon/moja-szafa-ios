import { GatewayError } from './managed-auth.mjs';

export class GatewayStore {
  constructor(pool, operations) {
    this.pool = pool;
    this.operations = new Set(operations);
    for (const operation of this.operations) if (!/^api_v1_[a-z_]+$/.test(operation)) throw new Error('invalid_rpc_contract');
  }
  async transaction(work) {
    const client = await this.pool.connect();
    try {
      // The LOGIN is NOINHERIT; activate only the narrow gateway role per transaction.
      // These fixed statements contain no input and share one network round trip.
      await client.query("BEGIN; SET LOCAL ROLE szafa_gateway; SET LOCAL statement_timeout = '10s'");
      const value = await work(client);
      await client.query('COMMIT');
      return value;
    } catch (error) { await client.query('ROLLBACK').catch(() => {}); throw error; }
    finally { client.release(); }
  }
  async bind(client, principal) {
    const result = await client.query('SELECT gateway_private.bind_session($1::uuid, $2::uuid) AS allowed', [principal.owner, principal.sessionID]);
    if (result.rows[0]?.allowed !== true) throw new GatewayError('unauthorized', 401);
  }
  async pruneTelemetry() {
    return this.transaction(client => client.query('SELECT app.telemetry_prune() AS removed'));
  }
  async retiredImages() {
    return this.transaction(async client => (await client.query('SELECT gateway_private.retired_images() AS items')).rows[0].items);
  }
  async acknowledgeRetiredImage(id) {
    return this.transaction(client => client.query('SELECT gateway_private.acknowledge_retired_image($1::uuid)', [id]));
  }
  async pruneExports() {
    return this.transaction(client => client.query('SELECT gateway_private.prune_exports()'));
  }
  async session(principal) { return this.transaction(client => this.bind(client, principal)); }
  async receiveSubscription(principal, event) {
    return this.transaction(async client => {
      if (principal) {
        await this.bind(client, principal);
        if (event.transaction.owner !== principal.owner.toLowerCase()) throw new GatewayError('subscription_account_mismatch', 403);
      }
      const result = await client.query('SELECT app.apple_subscription_receive($1::jsonb) AS response', [JSON.stringify(event)]);
      return result.rows[0].response;
    });
  }
  async subscriptionStatus(principal, environment) {
    return this.transaction(async client => {
      await this.bind(client, principal);
      const result = await client.query('SELECT app.apple_subscription_status($1::uuid,$2::text) AS response', [principal.owner, environment]);
      return result.rows[0].response;
    });
  }
  async rpc(principal, operation, request) {
    if (!this.operations.has(operation)) throw new GatewayError('not_found', 404);
    return this.transaction(async client => {
      await this.bind(client, principal);
      await client.query('SET LOCAL ROLE authenticated');
      // The identifier comes ONLY from the checked-in contract allowlist; payloads stay parameters.
      const result = await client.query(`SELECT app.${operation}($1::jsonb) AS response`, [JSON.stringify(request)]);
      return result.rows[0].response;
    });
  }
  async challenge(email) {
    const result = await this.transaction(client => client.query('SELECT gateway_private.start_email_challenge($1::text) AS id', [email]));
    if (!result.rows[0]?.id) throw new GatewayError('rate_limited', 429);
    return result.rows[0].id;
  }
  async attempt(id) {
    const result = await this.transaction(client => client.query('SELECT gateway_private.email_challenge_attempt($1::uuid) AS email', [id]));
    if (!result.rows[0]?.email) throw new GatewayError('authentication_rejected', 401);
    return result.rows[0].email;
  }
  async consume(id) { await this.transaction(client => client.query('SELECT gateway_private.consume_email_challenge($1::uuid)', [id])); }
  async createDeletionReceipt(principal, challenge, hash) {
    return this.transaction(async client => {
      const result = await client.query('SELECT gateway_private.create_deletion_receipt($1::uuid,$2::uuid,$3::uuid,$4::text) AS result',
        [principal.owner, principal.sessionID, challenge, hash]);
      return result.rows[0]?.result;
    });
  }
  async deletionReceiptStatus(challenge, operation, hash) {
    return this.transaction(async client => {
      const result = await client.query('SELECT gateway_private.deletion_receipt_status($1::uuid,$2::uuid,$3::text) AS result', [challenge, operation, hash]);
      return result.rows[0]?.result === true;
    });
  }
  async deletionReauthentication(action, principal, { challenge = null, operation = null, freshSession = null } = {}) {
    return this.transaction(async client => {
      const result = await client.query('SELECT gateway_private.deletion_reauthentication($1,$2::uuid,$3::uuid,$4::uuid,$5::uuid,$6::uuid) AS result',
        [action, principal.owner, principal.sessionID, challenge, operation, freshSession]);
      return result.rows[0]?.result;
    });
  }
  async command(principal, kind, action, data) {
    return this.transaction(async client => {
      await this.bind(client, principal);
      const result = await client.query('SELECT gateway_private.resource_command($1::text,$2::text,$3::jsonb) AS response',
        [kind, action, JSON.stringify(data)]);
      return result.rows[0].response;
    });
  }
}
