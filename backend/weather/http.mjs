// POST keeps coarse coordinates out of ordinary URL/access logs.
// The gateway supplies its live managed-session authenticator.
export function weatherHandler({ authenticate, forecast }) {
  if (typeof authenticate !== 'function' || typeof forecast !== 'function') throw new Error('weather_configuration_invalid');
  return async (request, response) => {
    const send = (status, body) => {
      response.writeHead(status, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store',
        'X-Content-Type-Options': 'nosniff' });
      response.end(JSON.stringify(body));
    };
    try {
      if (!await authenticate(request.headers.authorization)) throw new Error();
    } catch { return send(401, { error: { code: 'unauthorized' } }); }
    if (request.method !== 'POST' || request.url !== '/v1/weather') return send(404, { error: { code: 'not_found' } });
    if (request.headers['content-type']?.split(';', 1)[0].trim() !== 'application/json') {
      return send(400, { error: { code: 'invalid_request' } });
    }
    let input;
    try {
      const chunks = []; let size = 0;
      for await (const chunk of request) {
        size += chunk.length;
        if (size > 1024) return send(413, { error: { code: 'request_too_large' } });
        chunks.push(chunk);
      }
      input = JSON.parse(Buffer.concat(chunks).toString('utf8'));
      if (!input || Array.isArray(input) || Object.keys(input).sort().join(',') !== 'latitude,longitude'
          || typeof input.latitude !== 'number' || !Number.isFinite(input.latitude) || Math.abs(input.latitude) > 90
          || typeof input.longitude !== 'number' || !Number.isFinite(input.longitude) || Math.abs(input.longitude) > 180) throw new Error();
    } catch { return send(400, { error: { code: 'invalid_request' } }); }
    try { return send(200, { data: await forecast(input) }); }
    catch { return send(503, { error: { code: 'weather_unavailable' } }); }
  };
}
