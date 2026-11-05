import { execFile } from 'node:child_process';

// libpq reads credentials from the worker's private environment, never argv.
// The dedicated NOINHERIT login must belong only to szafa_erasure.
export function neonErasureStore({ connectionString, sslRootCert, environment = process.env } = {}) {
  if (connectionString !== undefined) {
    try {
      const url = new URL(connectionString);
      if (!['postgres:','postgresql:'].includes(url.protocol) || !url.hostname.endsWith('.neon.tech') ||
          url.searchParams.get('sslmode') !== 'verify-full' || !sslRootCert?.startsWith('/')) throw new Error();
      environment = { PATH: process.env.PATH, HOME: process.env.HOME,
        PGHOST: url.hostname, PGPORT: url.port || '5432', PGUSER: decodeURIComponent(url.username),
        PGPASSWORD: decodeURIComponent(url.password), PGDATABASE: decodeURIComponent(url.pathname.slice(1)),
        PGSSLMODE: 'verify-full', PGSSLROOTCERT: sslRootCert, PGCONNECT_TIMEOUT: '10' };
      if (!environment.PGUSER || !environment.PGPASSWORD || !environment.PGDATABASE) throw new Error();
    } catch { throw new Error('secure_erasure_database_configuration_required'); }
  }
  function query(sql, { signal } = {}) {
    signal?.throwIfAborted();
    return new Promise((resolve, reject) => {
      const child = execFile('psql', ['-XqAt', '-v', 'ON_ERROR_STOP=1'],
        { timeout: 15_000, maxBuffer: 1024 * 1024, signal, env: environment }, (error, stdout) => {
          if (error) return reject(new Error('erasure_store_unavailable'));
          try { resolve(JSON.parse(stdout.trim())); } catch { reject(new Error('erasure_store_unavailable')); }
        });
      child.stdin.on('error', () => {});
      child.stdin.end(sql);
    });
  }
  function call(action,args={},options={}) {
    const encoded=Buffer.from(JSON.stringify({...args,action})).toString('hex');
    return query(`BEGIN; SET LOCAL ROLE szafa_erasure; SET LOCAL statement_timeout='10s'; SELECT gateway_private.erasure_command(convert_from(decode('${encoded}','hex'),'UTF8')::jsonb); COMMIT;`,options);
  }
  const store = { call, deferReplica: args => call('deferReplica', args), async verifyRole() {
    const allowed=await query(`SELECT to_jsonb(NOT rolbypassrls AND NOT rolsuper AND NOT rolinherit
      AND pg_has_role(current_user,'szafa_erasure','MEMBER')
      AND NOT pg_has_role(current_user,'szafa_gateway','MEMBER')
      AND NOT pg_has_role(current_user,'service_role','MEMBER')
      AND NOT EXISTS(SELECT FROM pg_database WHERE datdba=pg_roles.oid))
      FROM pg_roles WHERE rolname=current_user;`);
    if(allowed!==true)throw new Error('least_privilege_erasure_role_required');
  } };
  for (const action of ['assertLease', 'revokeSessions', 'hasAppleIdentity', 'approveDeletion', 'identityAbsent', 'imageIDs']) {
    store[action] = (owner, options) => call(action, { owner, job: options.job, fence: options.fence }, options);
  }
  return store;
}
