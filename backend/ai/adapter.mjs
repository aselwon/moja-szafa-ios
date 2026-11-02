#!/usr/bin/env node
import { pathToFileURL } from 'node:url';
import { isAbsolute, resolve } from 'node:path';
import { createProvider, serverConfiguration } from './provider.mjs';
import { createAIExecutor } from './executor.mjs';
import { postgresStore } from '../worker/worker.mjs';

// Deliberately no fallback runtime or mock. Installed module is trusted server code
// supplying storage, domain validation, recipient binding and durable telemetry.
async function executeAdapter({ env, stdin }) {
  const configuration = serverConfiguration(env);
  const runtimePath = env.AI_RUNTIME_MODULE;
  if (!runtimePath || !isAbsolute(runtimePath)) throw new Error('configuration_invalid');
  const runtime = await import(pathToFileURL(runtimePath).href);
  if (typeof runtime.authorizeRecipient !== 'function') throw new Error('configuration_invalid');
  const store = postgresStore();
  const execute = createAIExecutor({ provider: createProvider(configuration),
    resolveInput: runtime.resolveInput, validateResult: runtime.validateResult,
    recordTelemetry: runtime.recordTelemetry,
    authorize: async (job, recipient) => await runtime.authorizeRecipient(job, recipient) === true &&
      await store.authorize(job) === true });
  let input = '';
  for await (const chunk of stdin) {
    input += chunk;
    if (Buffer.byteLength(input) > 64 * 1024) throw new Error('input_invalid');
  }
  const job = JSON.parse(input);
  if (!job || typeof job !== 'object') throw new Error('input_invalid');
  return execute(job);
}

export async function adapterResponse({ env = process.env, stdin = process.stdin } = {}) {
  try { return await executeAdapter({ env, stdin }); }
  catch { return { outcome: 'permanent' }; }
}
if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  process.stdout.write(JSON.stringify(await adapterResponse()) + '\n');
}
