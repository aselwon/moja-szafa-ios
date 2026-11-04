import test from 'node:test';
import assert from 'node:assert/strict';
import { Readable } from 'node:stream';
import { weatherHandler } from '../weather/http.mjs';

test('weather route authenticates before provider access and rejects owner injection', async () => {
  let calls = 0;
  const handler = weatherHandler({ authenticate: async header => header === 'Bearer valid' ? 'account' : null,
    forecast: async input => { calls++; assert.deepEqual(input, { latitude: 52.23, longitude: 21.01 }); return { celsius: 8.5 }; } });
  async function invoke(body, authorization = 'Bearer valid', method = 'POST') {
    const request = Readable.from([Buffer.from(typeof body === 'string' ? body : JSON.stringify(body))]);
    Object.assign(request, { method, url: '/v1/weather', headers: { authorization, 'content-type': 'application/json' } });
    const result = {};
    await handler(request, { writeHead(status, headers) { Object.assign(result, { status, headers }); },
      end(body) { result.body = JSON.parse(body); } });
    return result;
  }
  const city = { latitude: 52.23, longitude: 21.01 };
  assert.equal((await invoke(city, 'Bearer expired')).status, 401);
  for (const invalid of [{ ...city, owner: 'someone' }, { latitude: 91, longitude: 0 }, [], null, '{broken']) {
    assert.equal((await invoke(invalid)).status, 400);
  }
  assert.equal((await invoke(' '.repeat(1025))).status, 413);
  assert.equal((await invoke(city, 'Bearer valid', 'GET')).status, 404);
  assert.equal(calls, 0);
  const success = await invoke(city);
  assert.equal(success.status, 200);
  assert.equal(success.headers['Cache-Control'], 'no-store');
  assert.equal(success.body.data.celsius, 8.5);
  assert.equal(calls, 1);
});
