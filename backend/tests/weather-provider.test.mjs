import test from 'node:test';
import assert from 'node:assert/strict';
import { createWeatherProvider } from '../weather/met.mjs';

const start = Date.parse('2026-11-04T11:30:00Z');
const city = { latitude: 52.2297, longitude: 21.0122 };
function data() {
  return { properties: { meta: { updated_at: '2026-11-04T09:17:25Z', units: { air_temperature: 'celsius' } },
    timeseries: [12, 13, 14].map(hour => ({ time: `2026-11-04T${hour}:00:00Z`,
      data: { instant: { details: { air_temperature: 8.5 } } } })) } };
}
function response(body = data(), expires = start + 600_000) {
  return Response.json(body, { headers: { Expires: new Date(expires).toUTCString(),
    'Last-Modified': 'Wed, 04 Nov 2026 11:15:04 GMT' } });
}

test('identifies app, rounds coordinates, and preserves actual source update time', async () => {
  let calls = 0;
  const get = createWeatherProvider({ now: () => start, fetcher: async (url, options) => {
    calls++;
    assert.equal(url, 'https://api.met.no/weatherapi/locationforecast/2.0/compact?lat=52.23&lon=21.01');
    assert.match(options.headers['User-Agent'], /github.com\/aselwon\/moja-szafa-ios/);
    assert.equal(options.redirect, 'error');
    assert.equal(options.headers.Authorization, undefined);
    return response();
  } });
  const result = await get(city);
  assert.equal(result.updatedAt, '2026-11-04T09:17:25Z');
  assert.equal(result.validAt, '2026-11-04T12:00:00Z');
  assert.equal(result.celsius, 8.5);
  assert.equal(result.source, 'MET Norway');
  await assert.rejects(get({ latitude: Infinity, longitude: 0 }));
  await assert.rejects(get({ latitude: 0, longitude: 181 }));
  assert.equal(calls, 1);
});

test('honors Expires and conditionally revalidates with 304 without changing issue time', async () => {
  let time = start, calls = 0;
  const get = createWeatherProvider({ now: () => time, fetcher: async (_url, options) => {
    if (++calls === 1) return response();
    assert.equal(options.headers['If-Modified-Since'], 'Wed, 04 Nov 2026 11:15:04 GMT');
    return new Response(null, { status: 304, headers: { Expires: new Date(time + 600_000).toUTCString() } });
  } });
  await get(city); time += 599_000; await get(city); assert.equal(calls, 1);
  time += 2000; const result = await get(city); assert.equal(calls, 2);
  assert.equal(result.updatedAt, '2026-11-04T09:17:25Z');
  await get(city); assert.equal(calls, 2);
});

test('coalesces concurrent city requests and bounds aggregate upstream traffic', async () => {
  let calls = 0, release;
  const gate = new Promise(resolve => { release = resolve; });
  const get = createWeatherProvider({ now: () => start, fetcher: async () => { calls++; await gate; return response(); } });
  const reads = Array.from({ length: 20 }, () => get(city));
  await assert.rejects(get({ latitude: 1, longitude: 2 }));
  release(); await Promise.all(reads); assert.equal(calls, 1);
});

test('honors throttling and rejects stale or malformed provider data', async () => {
  let calls = 0, time = start;
  const get = createWeatherProvider({ now: () => time, fetcher: async () => {
    calls++; return new Response(null, { status: 429, headers: { 'Retry-After': '120' } });
  } });
  await assert.rejects(get(city)); time += 61_000;
  await assert.rejects(get(city)); assert.equal(calls, 1);
  for (const corrupt of [body => { body.properties.meta.updated_at = '2026-11-01T00:00:00Z'; },
    body => { body.properties.meta.units.air_temperature = 'fahrenheit'; },
    body => { body.properties.timeseries[0].data.instant.details.air_temperature = 100; }]) {
    const body = data(); corrupt(body);
    const invalid = createWeatherProvider({ now: () => start, fetcher: async () => response(body) });
    await assert.rejects(invalid(city), /weather_unavailable/);
  }
});

test('does not serve expired cached data when refresh fails and bounds response size', async () => {
  let time = start, calls = 0;
  const get = createWeatherProvider({ now: () => time, fetcher: async () => {
    if (++calls === 1) return response();
    return new Response('x'.repeat(2 * 1024 * 1024 + 1), { headers: { 'Content-Type': 'application/json' } });
  } });
  await get(city); time += 601_000;
  await assert.rejects(get(city));
  await assert.rejects(get(city)); assert.equal(calls, 2);
});
