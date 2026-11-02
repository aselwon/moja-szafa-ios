// Recovery is complete only after both data stores and deletion replay are verified.
export function recoveryMetrics({ incidentAt, databasePoint, imagesPoint, verifiedAt, deletionsVerified }) {
  const parse = value => {
    if (typeof value !== 'string' || !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/.test(value)) {
      throw new Error('UTC timestamp required');
    }
    const result = Date.parse(value);
    if (!Number.isFinite(result) || new Date(result).toISOString() !== value) throw new Error('Invalid timestamp');
    return result;
  };
  const incident = parse(incidentAt);
  const database = parse(databasePoint);
  const images = parse(imagesPoint);
  const verified = parse(verifiedAt);
  if (database > incident || images > incident || verified < incident) throw new Error('Invalid recovery chronology');
  const rpoSeconds = (incident - Math.min(database, images)) / 1000;
  const rtoSeconds = (verified - incident) / 1000;
  return { rpoSeconds, rtoSeconds, rpoMet: rpoSeconds <= 86400,
    rtoMet: rtoSeconds <= 28800, deletionsVerified: deletionsVerified === true,
    passed: rpoSeconds <= 86400 && rtoSeconds <= 28800 && deletionsVerified === true };
}
