import { execFile } from 'node:child_process';
import { pathToFileURL } from 'node:url';
import { resolve } from 'node:path';
import { setTimeout as sleep } from 'node:timers/promises';

// No shell, command-line payloads, or subprocess stderr in application logs.
function subprocess(command, args, input, timeout) {
  return new Promise((resolve, reject) => {
    const child = execFile(command, args, { timeout, killSignal: 'SIGKILL', maxBuffer: 1024 * 1024 },
      (error, stdout) => {
        if (error) reject(new Error(error.killed && error.code !== 'ERR_CHILD_PROCESS_STDIO_MAXBUFFER'
          ? 'timeout' : 'subprocess_failed'));
        else {
          try { resolve(JSON.parse(stdout)); }
          catch { reject(new Error('invalid_output')); }
        }
      });
    child.stdin.on('error', () => {}); // Exit/timeout can close stdin first.
    child.stdin.end(input);
  });
}

export function postgresStore() {
  // libpq service configuration supplies the dedicated server identity. Never
  // pass credentials on argv. SQL values are base64 encoded, not interpolated.
  const query = sql => subprocess('psql', ['-X', '-q', '-t', '-A', '-v', 'ON_ERROR_STOP=1'], sql, 10_000);
  const json = value => `convert_from(decode('${Buffer.from(JSON.stringify(value)).toString('base64')}','base64'),'UTF8')::jsonb`;
  return {
    claim: () => query('SELECT coalesce(app.jobs_claim(), \'null\'::jsonb);'),
    finish: (job, outcome, output = null) => {
      const data = json({ id: job.id, token: job.lease_token, outcome, output });
      return query(`WITH v AS (SELECT ${data} AS body) SELECT to_json(app.jobs_finish(
        (body->>'id')::uuid,(body->>'token')::uuid,body->>'outcome',body->'output')) FROM v;`);
    }
  };
}

export function processExecutor(adapterPath, timeout = 45_000) {
  if (!Number.isInteger(timeout) || timeout < 1 || timeout > 45_000) throw new Error('invalid_timeout');
  return job => subprocess(resolve(adapterPath), [], JSON.stringify(job) + '\n', timeout);
}

export async function runOnce(store, execute) {
  const job = await store.claim();
  if (!job) return false;
  let response;
  try {
    response = await execute(job);
    if (!response || !['success', 'retry', 'permanent'].includes(response.outcome) ||
        (response.outcome === 'success' && (!response.output || typeof response.output !== 'object' || Array.isArray(response.output)))) {
      response = { outcome: 'permanent' };
    }
  } catch (error) {
    response = { outcome: error?.message === 'timeout' ? 'timeout' : 'permanent' };
  }
  // A lost commit response is never converted into another attempt here. Leave
  // recovery to PostgreSQL; a committed success is already terminal and settled.
  await store.finish(job, response.outcome, response.output ?? null);
  return true;
}

async function main() {
  const adapterPath = process.argv[2];
  if (!adapterPath) throw new Error('adapter_required');
  // Validate installation before claiming jobs; no default fake/paid provider.
  const { access, constants } = await import('node:fs/promises');
  await access(resolve(adapterPath), constants.X_OK);
  const store = postgresStore();
  const execute = processExecutor(adapterPath);
  let stopping = false;
  process.on('SIGTERM', () => { stopping = true; });
  process.on('SIGINT', () => { stopping = true; });
  while (!stopping) {
    try {
      const worked = await runOnce(store, execute);
      if (!worked && !stopping) await sleep(1000);
    } catch {
      // Deliberately omit exception messages, payloads, URLs and credentials.
      process.stderr.write('worker_storage_unavailable\n');
      if (!stopping) await sleep(1000);
    }
  }
}
if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  main().catch(() => { process.stderr.write('worker_start_failed\n'); process.exitCode = 1; });
}
