import { DataExports } from '../exports/service.mjs';

// Schedule after completion so slow cleanup never overlaps itself. The store
// exposes only a fixed maintenance operation, never arbitrary owners or paths.
export function startExportRetention({ store, directory, intervalMs = 60_000,
  onError = () => process.stderr.write('gateway_export_retention_failed\n') }) {
  const exports = new DataExports({ directory, store: { call: () => store.pruneExports() } });
  let stopped = false, timer, current;
  const tick = () => {
    current = (async () => {
      try { await exports.sweep(); }
      catch { onError(); }
      finally {
        if (!stopped) { timer = setTimeout(tick, intervalMs); timer.unref(); }
      }
    })();
  };
  tick();
  return { ready: current, async stop() { stopped = true; clearTimeout(timer); await current; } };
}
