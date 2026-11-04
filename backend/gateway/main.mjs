import { readFile } from 'node:fs/promises';
import { isAbsolute } from 'node:path';
import { Pool } from 'pg';
import { ManagedAuth } from './managed-auth.mjs';
import { GatewayStore } from './store.mjs';
import { createGateway } from './server.mjs';
import { privateFiles } from '../images/pipeline.mjs';

async function main() {
  const env = process.env;
  if (!env.DATABASE_URL || !env.NEON_AUTH_BASE_URL || !isAbsolute(env.PRIVATE_IMAGE_DIRECTORY ?? '') ||
      !isAbsolute(env.EXPORT_DIRECTORY ?? '') || !/^[a-f0-9]{64}$/i.test(env.IMAGE_SIGNING_KEY ?? '')) {
    throw new Error('gateway_configuration_required');
  }
  const database = new URL(env.DATABASE_URL);
  if (!['postgres:', 'postgresql:'].includes(database.protocol) || !database.hostname.endsWith('.neon.tech') ||
      database.searchParams.get('sslmode') !== 'verify-full') throw new Error('secure_database_configuration_required');
  const pool = new Pool({ connectionString: env.DATABASE_URL, max: 4, connectionTimeoutMillis: 10000,
    idleTimeoutMillis: 10000, allowExitOnIdle: true });
  pool.on('error', () => process.stderr.write('gateway_database_unavailable\n'));
  const role = await pool.query(`SELECT current_user AS name, rolbypassrls AS bypass, rolsuper AS super,
    pg_has_role(current_user, 'service_role', 'MEMBER') AS worker,
    pg_has_role(current_user, 'szafa_gateway', 'MEMBER') AS gateway
    FROM pg_roles WHERE rolname=current_user`);
  if (!role.rows[0]?.gateway || role.rows[0]?.worker || role.rows[0]?.bypass || role.rows[0]?.super || ['szafa_owner', 'service_role'].includes(role.rows[0]?.name)) throw new Error('least_privilege_database_role_required');
  const contracts = [JSON.parse(await readFile(new URL('../api/openapi-v1.json', import.meta.url), 'utf8'))];
  // T034 installs the separately versioned AI surface alongside its SQL migration.
  try { contracts.push(JSON.parse(await readFile(new URL('../api/openapi-ai-v1.json', import.meta.url), 'utf8'))); }
  catch (error) { if (error.code !== 'ENOENT') throw error; }
  const operations = contracts.flatMap(contract => Object.values(contract.paths).map(route => route.post.operationId));
  const store = new GatewayStore(pool, operations);
  const server = createGateway({ auth: new ManagedAuth({ baseURL: env.NEON_AUTH_BASE_URL }), store,
    storage: privateFiles(env.PRIVATE_IMAGE_DIRECTORY), signingKey: Buffer.from(env.IMAGE_SIGNING_KEY, 'hex'),
    exportDirectory: env.EXPORT_DIRECTORY });
  const port = Number(env.PORT ?? 8080);
  if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error('invalid_port');
  server.listen(port, '127.0.0.1', () => process.stdout.write('gateway_ready\n'));
  for (const signal of ['SIGTERM', 'SIGINT']) process.once(signal, () => {
    server.close(() => pool.end().then(() => process.exit(0)));
    setTimeout(() => process.exit(1), 15000).unref();
  });
}
main().catch(() => { process.stderr.write('gateway_start_failed\n'); process.exitCode = 1; });
