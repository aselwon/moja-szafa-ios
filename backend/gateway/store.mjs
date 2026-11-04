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
      await client.query('BEGIN');
      // The LOGIN is NOINHERIT; activate only the narrow gateway role per transaction.
      await client.query('SET LOCAL ROLE szafa_gateway');
      await client.query("SET LOCAL statement_timeout = '10s'");
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
  async session(principal) { return this.transaction(client => this.bind(client, principal)); }
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
  async command(principal, kind, action, data) {
    return this.transaction(async client => {
      await this.bind(client, principal);
      const result = await client.query('SELECT gateway_private.resource_command($1::text,$2::text,$3::jsonb) AS response',
        [kind, action, JSON.stringify(data)]);
      return result.rows[0].response;
    });
  }
}
