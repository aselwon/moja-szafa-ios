import { validatePurchaseFit } from '../purchases/candidate.mjs';
import { validateRecognition, recognitionDraft } from './recognition.mjs';
import { validateOutfits } from './outfits.mjs';
import { AIError } from './provider.mjs';
import { candidateMetadata, selectCandidates, eligibleGarments } from './candidates.mjs';

// Trusted server composition only, never take these hooks or provider config from a job.
// resolveInput checks current ownership/availability and loads normalized private bytes.
// validateResult must perform feature schema + domain validation before persistence.
// authorize checks the lease/current consent AND configured recipient after input resolution.
export function createAIExecutor({ provider, resolveInput, validateResult, authorize, recordTelemetry }) {
  if (!provider || !['analyzeImage', 'recommendOutfits'].every(key => typeof provider[key] === 'function') ||
      typeof provider.recipient !== 'string' ||
      [resolveInput, validateResult, authorize, recordTelemetry].some(value => typeof value !== 'function')) {
    throw new AIError('configuration_invalid');
  }
  return async job => {
    if (!['image_analysis', 'outfit_generation', 'purchase_fit'].includes(job.kind)) return { outcome: 'permanent' };
    let telemetry;
    let output;
    let providerCall = 1;
    try {
      let input = await resolveInput(job);
      if (job.kind !== 'image_analysis') input = prepareInput(input, job);
      if (await authorize(job, provider.recipient) !== true) return { outcome: 'permanent' };
      let response;
      try {
        response = await (job.kind === 'image_analysis' ? provider.analyzeImage(input) : provider.recommendOutfits(input));
      } catch (error) {
        if (!['outfit_generation','purchase_fit'].includes(job.kind) || !(error instanceof AIError) || error.message !== 'outfit_json_invalid') throw error;
        // Account for the first charged response before permitting one JSON repair.
        await recordTelemetry({ job_id: job.id, attempt: job.attempt, provider_call: providerCall, ...error.telemetry });
        providerCall = 2;
        input = prepareInput(await resolveInput(job), job);
        if (await authorize(job, provider.recipient) !== true) return { outcome: 'permanent' };
        response = await provider.recommendOutfits(input, { repairJSON: true });
      }
      telemetry = response.telemetry;
      let candidate = job.kind === 'image_analysis' ? validateRecognition(response.result) : validateRecommendation(response.result, input, job);
      if (job.kind !== 'image_analysis') {
        // Resolve again after the provider await: laundry/archive may have changed.
        const refreshed = await resolveInput(job);
        const current = { garments: eligibleGarments(refreshed, job.user_id) };
        if (job.kind === 'purchase_fit' && JSON.stringify(candidateMetadata(refreshed.purchase_candidate)) !== JSON.stringify(input.purchase_candidate)) throw new AIError('result_invalid');
        assertEligibleResult(candidate, input, current);
        candidate = validateRecommendation(response.result, { ...input, garments: current.garments }, job);
      }
      const validated = await validateResult(job, candidate, input);
      const result = job.kind === 'image_analysis' ? recognitionDraft(validated) : validated;
      if (!result || typeof result !== 'object' || Array.isArray(result)) throw new AIError('result_invalid');
      output = { result, telemetry };
    } catch (error) {
      telemetry ??= error instanceof AIError ? error.telemetry : undefined;
      if (telemetry) await recordTelemetry({ job_id: job.id, attempt: job.attempt, provider_call: providerCall, ...telemetry, status: telemetry.status === 'success' ? 'result_rejected' : telemetry.status });
      // No automatic retries: timeouts/transport/5xx may already have incurred a charge.
      return { outcome: 'permanent' };
    }
    // A failed telemetry write must not cause an immediate second provider request.
    // Production sink must be durable and deduplicate by job_id + attempt + provider_call.
    await recordTelemetry({ job_id: job.id, attempt: job.attempt, provider_call: providerCall, ...telemetry });
    return { outcome: 'success', output };
  };
}

function assertEligibleResult(result, sent, current) {
  const allowed = new Set(current.garments.map(g => g.id));
  const supplied = new Set(sent.garments.map(g => g.id));
  if (!Array.isArray(result?.outfits) || result.outfits.some(outfit =>
    !Array.isArray(outfit.garment_ids) || !outfit.garment_ids.length ||
    outfit.garment_ids.some(id => !allowed.has(id) || !supplied.has(id)))) {
    throw new AIError('result_invalid');
  }
}

function prepareInput(raw, job) {
  const selected = selectCandidates(raw, job.user_id);
  if (job.kind !== 'purchase_fit') return selected;
  const candidate = candidateMetadata(raw.purchase_candidate);
  if (selected.garments.some(g => g.id === candidate.id)) throw new AIError('result_invalid');
  return { ...selected, purchase_candidate: candidate };
}
function validateRecommendation(raw, input, job) {
  return job.kind === 'purchase_fit' ? validatePurchaseFit(raw, input) : validateOutfits(raw, input);
}
