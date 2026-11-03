import { validateRecognition, recognitionDraft } from './recognition.mjs';
import { AIError } from './provider.mjs';

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
    if (!['image_analysis', 'outfit_generation'].includes(job.kind)) return { outcome: 'permanent' };
    let telemetry;
    let output;
    try {
      const input = await resolveInput(job);
      if (await authorize(job, provider.recipient) !== true) return { outcome: 'permanent' };
      const response = await (job.kind === 'image_analysis' ? provider.analyzeImage(input) : provider.recommendOutfits(input));
      telemetry = response.telemetry;
      const candidate = job.kind === 'image_analysis' ? validateRecognition(response.result) : response.result;
      const validated = await validateResult(job, candidate, input);
      const result = job.kind === 'image_analysis' ? recognitionDraft(validated) : validated;
      if (!result || typeof result !== 'object' || Array.isArray(result)) throw new AIError('result_invalid');
      output = { result, telemetry };
    } catch (error) {
      telemetry ??= error instanceof AIError ? error.telemetry : undefined;
      if (telemetry) await recordTelemetry({ job_id: job.id, attempt: job.attempt, ...telemetry, status: telemetry.status === 'success' ? 'result_rejected' : telemetry.status });
      // No automatic retries: timeouts/transport/5xx may already have incurred a charge.
      return { outcome: 'permanent' };
    }
    // A failed telemetry write must not cause an immediate second provider request.
    // Production sink must be durable and deduplicate by job_id + attempt.
    await recordTelemetry({ job_id: job.id, attempt: job.attempt, ...telemetry });
    return { outcome: 'success', output };
  };
}
