import test from 'node:test';
import assert from 'node:assert/strict';
import { weatherContext } from '../weather/context.mjs';
import { selectCandidates } from '../ai/candidates.mjs';

test('candidate selection carries only valid weather and never requires it for eligible clothing', () => {
  const garments = [{ id: 'owned-top', user_id: 'owner', category: 'top', availability: 'available', archived: false }];
  const base = { garments, count: 3 };
  const manual = selectCandidates({ ...base, weather: { source: 'manual', temperature_celsius: -5 } }, 'owner');
  assert.deepEqual(manual.weather, { source: 'manual', temperature_celsius: -5 });
  const absent = selectCandidates(base, 'owner');
  const expired = selectCandidates({ ...base, weather: { source: 'forecast', temperature_celsius: 12, valid_until: 1 } }, 'owner');
  assert.equal(absent.weather, undefined);
  assert.equal(expired.weather, undefined);
  assert.deepEqual(expired.garments, manual.garments);
  assert.deepEqual(absent.garments, manual.garments);
});

test('optional weather survives denied location, manual input, and a delayed job', () => {
  const now = 1800000000000;
  assert.equal(weatherContext(undefined, now), null);
  assert.equal(weatherContext(null, now), null);
  assert.deepEqual(weatherContext({ source: 'manual', temperature_celsius: -5.5 }, now),
    { source: 'manual', temperature_celsius: -5.5 });
  const forecast = { source: 'forecast', temperature_celsius: 12, valid_until: now / 1000 + 1800 };
  assert.deepEqual(weatherContext(forecast, now), { source: 'forecast', temperature_celsius: 12 });
  assert.equal(weatherContext(forecast, now + 1801_000), null);
  for (const value of [{ ...forecast, city: 'private' }, { ...forecast, latitude: 50 },
    { ...forecast, valid_until: now / 1000 + 7201 }, { source: 'manual', temperature_celsius: NaN },
    { source: 'manual', temperature_celsius: 61 }, { source: 'unknown', temperature_celsius: 10 }]) {
    assert.throws(() => weatherContext(value, now), /weather_context_invalid/);
  }
});
