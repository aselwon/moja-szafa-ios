// Optional outfit hint only. City, coordinates, timezone and arbitrary free text
// are deliberately excluded from provider prompts.
export function weatherContext(value, now = Date.now()) {
  if (value == null) return null;
  if (typeof value !== 'object' || Array.isArray(value)
      || !['manual', 'forecast'].includes(value.source)
      || typeof value.temperature_celsius !== 'number' || !Number.isFinite(value.temperature_celsius)
      || value.temperature_celsius < -80 || value.temperature_celsius > 60) throw new Error('weather_context_invalid');
  const expected = value.source === 'forecast'
    ? 'source,temperature_celsius,valid_until' : 'source,temperature_celsius';
  if (Object.keys(value).sort().join(',') !== expected) throw new Error('weather_context_invalid');
  if (value.source === 'forecast') {
    if (!Number.isSafeInteger(value.valid_until)) throw new Error('weather_context_invalid');
    // A queued/replayed job may outlive the forecast. Continue without weather
    // rather than reject a valid outfit request or present stale advice as fresh.
    if (value.valid_until * 1000 < now) return null;
    if (value.valid_until * 1000 > now + 2 * 3600_000) throw new Error('weather_context_invalid');
  }
  return { temperature_celsius: value.temperature_celsius, source: value.source };
}
