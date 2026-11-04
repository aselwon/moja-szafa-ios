// Read `xcrun simctl list runtimes -j` and choose a compatible iPhone type.
import { readFileSync } from 'node:fs';

const { runtimes } = JSON.parse(readFileSync(0, 'utf8'));
const available = runtimes
  .filter(runtime => runtime.isAvailable && runtime.identifier.includes('.iOS-'))
  .sort((a, b) => b.version.localeCompare(a.version, 'en', { numeric: true }));
for (const runtime of available) {
  const device = runtime.supportedDeviceTypes?.find(type => type.productFamily === 'iPhone');
  if (device) {
    console.log(`${device.identifier} ${runtime.identifier}`);
    process.exit(0);
  }
}
console.error('No available iOS runtime with a compatible iPhone device type');
process.exit(1);
