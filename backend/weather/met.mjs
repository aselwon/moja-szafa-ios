// Server-side only: callers must authenticate before requesting a forecast.
// Never forward user identifiers, IP addresses or arbitrary URLs to the provider.
const endpoint = 'https://api.met.no/weatherapi/locationforecast/2.0/compact';
const userAgent = 'MojaSzafa/0.1 (+https://github.com/aselwon/moja-szafa-ios)';
const unavailable = () => new Error('weather_unavailable');

function coordinate(value, maximum) {
  if (typeof value !== 'number' || !Number.isFinite(value) || Math.abs(value) > maximum) throw unavailable();
  // City-level resolution also gives nearby requests a shared cache key.
  return (Math.round(value * 100) / 100).toFixed(2);
}

function forecast(data, now, deprecated) {
  const properties = data?.properties;
  const updated = Date.parse(properties?.meta?.updated_at);
  if (properties?.meta?.units?.air_temperature !== 'celsius' || !Number.isFinite(updated)
      || updated > now + 300_000 || now - updated > 12 * 3600_000
      || !Array.isArray(properties.timeseries)) throw unavailable();
  const next = properties.timeseries.find(point => {
    const time = Date.parse(point.time);
    return time >= now && time <= now + 2 * 3600_000;
  });
  const celsius = next?.data?.instant?.details?.air_temperature;
  if (typeof celsius !== 'number' || !Number.isFinite(celsius) || celsius < -80 || celsius > 60) throw unavailable();
  return { celsius, validAt: next.time, updatedAt: properties.meta.updated_at,
    source: 'MET Norway', attributionURL: 'https://api.met.no/',
    licenseURL: 'https://creativecommons.org/licenses/by/4.0/', deprecated };
}

async function readJSON(response) {
  if (!response.headers.get('content-type')?.includes('json') || !response.body) throw unavailable();
  const reader = response.body.getReader();
  const chunks = []; let size = 0;
  try {
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      size += value.length;
      if (size > 2 * 1024 * 1024) { await reader.cancel(); throw unavailable(); }
      chunks.push(value);
    }
    return JSON.parse(Buffer.concat(chunks).toString('utf8'));
  } finally { reader.releaseLock(); }
}

export function createWeatherProvider({ fetcher = fetch, now = Date.now, maxEntries = 100 } = {}) {
  if (!Number.isInteger(maxEntries) || maxEntries < 1 || maxEntries > 1000) throw unavailable();
  const cache = new Map();
  const pending = new Map();
  let nextRequest = 0;
  async function load(key) {
    const previous = cache.get(key);
    const time = now();
    if (previous?.expires > time) {
      if (!previous.data) throw unavailable();
      return previous;
    }
    // At most one new upstream request/second across all coordinates.
    if (time < nextRequest) throw unavailable();
    nextRequest = time + 1000;
    const headers = { 'User-Agent': userAgent, Accept: 'application/json' };
    if (previous?.modified) headers['If-Modified-Since'] = previous.modified;
    try {
      const response = await fetcher(`${endpoint}?${key}`, {
        headers, redirect: 'error', signal: AbortSignal.timeout(10_000)
      });
      if (![200, 203, 304].includes(response.status)) {
        if (response.status === 429) {
          const raw = response.headers.get('retry-after');
          const retry = /^\d+$/.test(raw ?? '') ? time + Number(raw) * 1000 : Date.parse(raw);
          nextRequest = Math.max(nextRequest, Number.isFinite(retry) ? retry : time + 60_000);
        }
        throw unavailable();
      }
      if (response.status === 304 && !previous?.data) throw unavailable();
      const data = response.status === 304 ? previous.data : await readJSON(response);
      const deprecated = response.status === 203 || (response.status === 304 && previous.deprecated);
      forecast(data, now(), deprecated); // Reject malformed/stale data before caching it.
      const expires = Date.parse(response.headers.get('expires'));
      const entry = { data, deprecated,
        expires: Number.isFinite(expires) && expires > time ? expires : time + 600_000,
        modified: response.headers.get('last-modified') ?? previous?.modified };
      cache.delete(key); cache.set(key, entry);
      while (cache.size > maxEntries) cache.delete(cache.keys().next().value);
      return entry;
    } catch {
      // A provider failure is not permission to serve stale weather as current.
      cache.delete(key); cache.set(key, { expires: now() + 60_000 });
      while (cache.size > maxEntries) cache.delete(cache.keys().next().value);
      throw unavailable();
    }
  }
  return async ({ latitude, longitude }) => {
    const key = `lat=${coordinate(latitude, 90)}&lon=${coordinate(longitude, 180)}`;
    if (!pending.has(key)) pending.set(key, load(key).finally(() => pending.delete(key)));
    const entry = await pending.get(key);
    return forecast(entry.data, now(), entry.deprecated);
  };
}
