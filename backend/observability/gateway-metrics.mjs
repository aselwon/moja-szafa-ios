import { mkdir, readFile, rename, writeFile } from 'node:fs/promises';
import { join, isAbsolute } from 'node:path';

export const LATENCY_BUCKETS_MS = Object.freeze([50, 100, 250, 500, 800, 1000, 2000, 5000, 10000, 30000, 60000]);
const methods = new Set(['GET', 'POST', 'PUT', 'DELETE', 'OTHER']);
const outcomes = new Set(['success', 'client_error', 'server_error', 'rpc_error', 'aborted']);
const integer = value => Number.isSafeInteger(value) && value >= 0;

/** Anonymous bounded aggregates only: never retain the URL, query, headers,
 * remote address, principal, request ID, body, error text or user identifier. */
export class GatewayMetrics {
  constructor({ operations = [], directory, now = () => new Date() } = {}) {
    if (directory !== undefined && !isAbsolute(directory)) throw new Error('metrics_directory_must_be_absolute');
    this.routes = new Set(['health', 'auth', 'weather', 'images', 'purchase_images', 'exports', 'unknown']);
    for (const name of operations instanceof Map ? operations.keys() : operations) {
      if (/^api_v1_[a-z_]{1,80}$/.test(name)) this.routes.add(`rpc:${name}`);
    }
    if (this.routes.size > 128) throw new Error('metrics_route_limit');
    this.directory = directory; this.now = now; this.rows = new Map(); this.flushing = null; this.dropped = 0;
  }
  route(pathname) {
    if (pathname === '/health') return 'health';
    if (pathname.startsWith('/auth/v1/')) return 'auth';
    if (pathname === '/v1/weather') return 'weather';
    if (pathname.startsWith('/v1/purchase-images/')) return 'purchase_images';
    if (pathname.startsWith('/v1/images/')) return 'images';
    if (pathname.startsWith('/v1/exports/')) return 'exports';
    const rpc = /^\/rest\/v1\/rpc\/(api_v1_[a-z_]+)$/.exec(pathname);
    return rpc && this.routes.has(`rpc:${rpc[1]}`) ? `rpc:${rpc[1]}` : 'unknown';
  }
  record({ route, method, status, durationMs, aborted = false, rpcError = false }) {
    if (!this.routes.has(route)) route = 'unknown';
    if (!methods.has(method)) method = 'OTHER';
    if (!Number.isFinite(durationMs) || durationMs < 0) return;
    const outcome = aborted ? 'aborted' : status >= 500 ? 'server_error' : status >= 400 ? 'client_error' : rpcError ? 'rpc_error' : 'success';
    const day = this.now().toISOString().slice(0, 10);
    const key = [day, route, method, outcome].join('|');
    this.prune();
    let row = this.rows.get(key);
    if (!row) {
      // The cap is a safety bound, not a label-cardinality escape hatch.
      if (this.rows.size >= 4096) { this.dropped = Math.min(Number.MAX_SAFE_INTEGER, this.dropped + 1); return; }
      row = { day, route, method, outcome, count: 0, total_ms: 0, max_ms: 0, buckets: LATENCY_BUCKETS_MS.map(() => 0), over_60s: 0 };
      this.rows.set(key, row);
    }
    const duration = Math.min(Math.round(durationMs), 3_600_000);
    if (row.count >= 1_000_000_000 || row.total_ms + duration > Number.MAX_SAFE_INTEGER) { this.dropped = Math.min(Number.MAX_SAFE_INTEGER, this.dropped + 1); return; }
    row.count++; row.total_ms += duration; row.max_ms = Math.max(row.max_ms, duration);
    const index = LATENCY_BUCKETS_MS.findIndex(limit => duration <= limit);
    if (index < 0) row.over_60s++; else row.buckets[index]++;
  }
  prune() {
    const earliest = new Date(this.now().getTime() - 6 * 86_400_000).toISOString().slice(0, 10);
    const today = this.now().toISOString().slice(0, 10);
    for (const [key, row] of this.rows) if (row.day < earliest || row.day > today) this.rows.delete(key);
  }
  snapshot() {
    this.prune();
    return { version: 1, bucket_upper_bounds_ms: [...LATENCY_BUCKETS_MS], retention_days: 7, dropped_samples: this.dropped,
      rows: [...this.rows.values()].map(row => ({ ...row, buckets: [...row.buckets] })) };
  }
  async restore() {
    if (!this.directory) return;
    let data;
    try { data = await readFile(join(this.directory, 'gateway-metrics.json')); }
    catch (error) { if (error.code === 'ENOENT') return; throw new Error('metrics_read_failed'); }
    if (data.length > 2 * 1024 * 1024) throw new Error('metrics_file_too_large');
    const value = JSON.parse(data);
    if (value.version !== 1 || !integer(value.dropped_samples) || JSON.stringify(value.bucket_upper_bounds_ms) !== JSON.stringify(LATENCY_BUCKETS_MS) || !Array.isArray(value.rows) || value.rows.length > 4096) throw new Error('invalid_metrics_file');
    const restored = new Map();
    const fields = ['day', 'route', 'method', 'outcome', 'count', 'total_ms', 'max_ms', 'buckets', 'over_60s'].sort().join(',');
    for (const row of value.rows) {
      if (!row || Object.keys(row).sort().join(',') !== fields || !/^\d{4}-\d{2}-\d{2}$/.test(row.day) ||
          !this.routes.has(row.route) || !methods.has(row.method) || !outcomes.has(row.outcome) ||
          ![row.count, row.total_ms, row.max_ms, row.over_60s].every(integer) || !Array.isArray(row.buckets) ||
          row.buckets.length !== LATENCY_BUCKETS_MS.length || !row.buckets.every(integer) ||
          row.buckets.reduce((sum, count) => sum + count, row.over_60s) !== row.count) throw new Error('invalid_metrics_row');
      const key = [row.day, row.route, row.method, row.outcome].join('|');
      if (restored.has(key)) throw new Error('duplicate_metrics_row');
      restored.set(key, row);
    }
    this.rows = restored; this.dropped = value.dropped_samples; this.prune();
  }
  async flush() {
    if (!this.directory) return;
    if (this.flushing) { await this.flushing; return this.flush(); }
    const data = JSON.stringify(this.snapshot());
    this.flushing = (async () => {
      await mkdir(this.directory, { recursive: true, mode: 0o700 });
      const temporary = join(this.directory, 'gateway-metrics.tmp');
      await writeFile(temporary, data, { mode: 0o600 });
      await rename(temporary, join(this.directory, 'gateway-metrics.json'));
    })();
    try { await this.flushing; } finally { this.flushing = null; }
  }
}
