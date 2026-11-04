import { prompts } from '../provider.mjs';

// Baseline always uses the production text. The candidate is an experiment only;
// it does not replace the production prompt or imply measured improvement.
export const baseline = prompts.outfit_generation;
export const candidate = Object.freeze({ version: 'outfit-generation-v3-eval',
  text: baseline.text + ' Treat preferences and season as ranking signals, not permission to invent garments. When preferences conflict with available essentials, explain the compromise. Prefer a winter layer when winter metadata is supplied, but do not promise thermal protection.' });
