import assert from 'node:assert/strict';
import { recoveryMetrics } from '../recovery/metrics.mjs';
const evidence = { incidentAt: '2026-11-02T00:00:00.000Z', databasePoint: '2026-11-01T12:00:00.000Z',
  imagesPoint: '2026-11-01T00:00:00.000Z', verifiedAt: '2026-11-02T08:00:00.000Z', deletionsVerified: true };
assert.deepEqual(recoveryMetrics(evidence), { rpoSeconds: 86400, rtoSeconds: 28800,
  rpoMet: true, rtoMet: true, deletionsVerified: true, passed: true });
assert.equal(recoveryMetrics({ ...evidence, imagesPoint: '2026-10-31T23:59:59.999Z' }).passed, false);
assert.equal(recoveryMetrics({ ...evidence, verifiedAt: '2026-11-02T08:00:00.001Z' }).passed, false);
for (const deletionsVerified of [false, undefined, 'true']) {
  assert.equal(recoveryMetrics({ ...evidence, deletionsVerified }).passed, false);
}
for (const [key, value] of [['databasePoint', '2026-11-03T00:00:00.000Z'],
  ['verifiedAt', '2026-11-01T00:00:00.000Z'], ['imagesPoint', '2026-02-30T00:00:00.000Z'],
  ['incidentAt', ''], ['incidentAt', null]]) {
  assert.throws(() => recoveryMetrics({ ...evidence, [key]: value }));
}
console.log('OK: recovery metrics, boundary failures and mandatory deletion verification');
