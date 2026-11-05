import { randomBytes } from 'node:crypto';
import { ImagePipeline, privateFiles } from '../images/pipeline.mjs';

// Only retired/expired uploads selected by PostgreSQL are removed. A failed
// disk removal is never acknowledged, so the durable queue retries it.
export function startImageRetention({ store, directory, intervalMs = 10_000,
  onError = () => process.stderr.write('gateway_image_retention_failed\n') }) {
  const pipeline = new ImagePipeline({ storage: privateFiles(directory), signingKey: randomBytes(32),
    store: { call(action, data) {
      if (action === 'sweep') return store.retiredImages();
      if (action === 'cleaned') return store.acknowledgeRetiredImage(data.id);
      throw new Error('unsupported_image_maintenance');
    } } });
  let stopped = false, timer, current;
  const tick = () => {
    current = (async () => {
      let count = 0;
      try { count = await pipeline.sweep(); }
      catch { onError(); }
      finally {
        if (!stopped) { timer = setTimeout(tick, count === 100 ? 0 : intervalMs); timer.unref(); }
      }
    })();
  };
  tick();
  return { ready: current, async stop() { stopped = true; clearTimeout(timer); await current; } };
}
