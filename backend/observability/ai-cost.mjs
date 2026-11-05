// Published model rates, not an invoice or a spending-cap implementation.
// https://developers.cloudflare.com/workers-ai/platform/pricing/ (2026-11-05).
export const AI_RATE_VERSION = 'cloudflare-neurons-2026-11-05';
const rates = new Map([
  ['@cf/meta/llama-3.1-8b-instruct-fp8', [13778n, 26128n]],
  ['@cf/meta/llama-3.1-8b-instruct-fp8-fast', [4119n, 34868n]],
  ['@cf/meta/llama-3.1-8b-instruct', [25608n, 75147n]],
  ['@cf/meta/llama-3.2-11b-vision-instruct', [4410n, 61493n]],
]);
const unsigned = value => /^(0|[1-9][0-9]{0,18})$/.test(String(value));
function decimal(value, scale) {
  const digits = value.toString().padStart(scale + 1, '0');
  return `${digits.slice(0, -scale)}.${digits.slice(-scale)}`;
}
export function estimateAICost(rows) {
  let neuronMillionths = 0n; let unknownCalls = 0n; let measuredCalls = 0n;
  for (const row of rows) {
    if (!unsigned(row.calls) || !unsigned(row.calls_with_usage) || BigInt(row.calls_with_usage) > BigInt(row.calls)) throw new Error('invalid_ai_counts');
    const calls = BigInt(row.calls), observed = BigInt(row.calls_with_usage);
    const rate = rates.get(row.model);
    if (row.provider !== 'cloudflare' || !rate || !unsigned(row.input_tokens) || !unsigned(row.output_tokens)) {
      unknownCalls += calls; continue;
    }
    unknownCalls += calls - observed; measuredCalls += observed;
    neuronMillionths += BigInt(row.input_tokens) * rate[0] + BigInt(row.output_tokens) * rate[1];
  }
  // $0.011 / 1000 neurons. Keep exact fixed-point strings without rounding each call.
  return { rate_version: AI_RATE_VERSION, source: 'https://developers.cloudflare.com/workers-ai/platform/pricing/',
    measured_calls: measuredCalls.toString(), unknown_cost_calls: unknownCalls.toString(),
    estimated_neurons_for_known_usage: decimal(neuronMillionths, 6),
    estimated_list_price_usd_for_known_usage: decimal(neuronMillionths * 11n, 12),
    invoice_cost_usd: null,
    qualification: 'List-price estimate before free allocation. Unknown usage is not zero. Other account traffic, billing plan and invoice are not measured. Call credits are separate from currency.' };
}
