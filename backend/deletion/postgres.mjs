import { execFile } from 'node:child_process';

function query(sql) {
  return new Promise((resolve, reject) => {
    const child = execFile('psql', ['-X', '-q', '-t', '-A', '-v', 'ON_ERROR_STOP=1'],
      { timeout: 10000, maxBuffer: 1024 * 1024 }, (error, stdout) => {
        if (error) return reject(new Error('deletion_storage_unavailable'));
        try { resolve(JSON.parse(stdout)); } catch { reject(new Error('invalid_storage_response')); }
      });
    child.stdin.on('error', () => {});
    child.stdin.end(sql);
  });
}
const uuid = value => {
  if (!/^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(value)) throw new Error('invalid_uuid');
  return `'${value}'::uuid`;
};
export function postgresDeletionStore() {
  return {
    enqueue: (owner, operation) => query(`SELECT to_json(app.deletion_enqueue(${uuid(owner)},${uuid(operation)}));`),
    claim: () => query("SELECT coalesce(app.deletion_claim(),'null'::jsonb);"),
    finish: (job, succeeded) => query(`SELECT to_json(app.deletion_finish(${uuid(job.id)},${uuid(job.token)},${succeeded === true}));`)
  };
}
