import { OperatorError } from './auth.mjs';

export class OperatorStore {
  constructor(pool) { this.pool = pool; }
  async command(actor, requestID, request) {
    const connection = await this.pool.connect();
    try {
      await connection.query('BEGIN');
      await connection.query("SET LOCAL statement_timeout='5s'");
      await connection.query("SET LOCAL lock_timeout='2s'");
      await connection.query('SET LOCAL ROLE szafa_ops');
      const { rows } = await connection.query('SELECT ops_private.command($1,$2,$3,$4::jsonb) AS result',
        [actor.issuer, actor.subject, requestID, JSON.stringify(request)]);
      // Denials also commit their audit event; database exceptions roll back
      // the entire operation, including a flag change whose audit write failed.
      await connection.query('COMMIT');
      return rows[0].result;
    } catch {
      await connection.query('ROLLBACK').catch(() => {});
      throw new OperatorError('operations_unavailable', 503);
    } finally { connection.release(); }
  }
}
