import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { fileURLToPath } from 'node:url';
import { estimateAICost } from './ai-cost.mjs';
import { GatewayMetrics } from './gateway-metrics.mjs';
import { loadRPCOperations } from '../gateway/contracts.mjs';

export function summarizeObservability(database, gateway) {
  const aiCost = estimateAICost(database.ai_calls ?? []);
  const policy = database.ai_policy;
  const alerts = [];
  if (policy?.enabled && policy.dispatched_call_credits_today >= policy.daily_global_call_credit_limit) alerts.push('ai_call_credit_limit_reached');
  else if (policy?.enabled && policy.dispatched_call_credits_today >= policy.daily_global_call_credit_limit * 0.8) alerts.push('ai_call_credits_at_80_percent');
  if (BigInt(aiCost.unknown_cost_calls) > 0n) alerts.push('ai_cost_coverage_incomplete');
  if (gateway?.dropped_samples > 0) alerts.push('gateway_metrics_dropped_samples');
  return { database, gateway, ai_cost: aiCost, alerts };
}

async function main() {
  let database;
  try {
    const { stdout } = await promisify(execFile)('psql', ['-X', '-A', '-t', '-v', 'ON_ERROR_STOP=1', '-f', fileURLToPath(new URL('./report.sql', import.meta.url))], {
      env: { ...process.env, ...(process.env.DATABASE_URL ? { PGDATABASE: process.env.DATABASE_URL } : {}) },
      maxBuffer: 4 * 1024 * 1024, timeout: 15000,
    });
    database = JSON.parse(stdout);
  } catch { throw new Error('operational_report_query_failed'); }
  let gateway = null;
  if (process.env.OBSERVABILITY_DIRECTORY) {
    const metrics = new GatewayMetrics({ directory: process.env.OBSERVABILITY_DIRECTORY, operations: await loadRPCOperations() });
    await metrics.restore(); gateway = metrics.snapshot();
  }
  process.stdout.write(JSON.stringify(summarizeObservability(database, gateway), null, 2) + '\n');
}
if (process.argv[1] === fileURLToPath(import.meta.url)) main().catch(() => {
  // Database/transport errors can contain connection details. Never echo them.
  process.stderr.write('operational_report_failed\n'); process.exitCode = 1;
});
