#!/usr/bin/env node
import { readFile, stat } from 'node:fs/promises';
import { isAbsolute, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { adapterResponse } from './adapter.mjs';

// Explicitly selected free-plan models; no AI Gateway paid routing or fallback.
export async function cloudflareEnvironment(env, {read=readFile,metadata=stat}={}) {
  if(env.CLOUDFLARE_WORKERS_PLAN!=='free'||!/^[a-f0-9]{32}$/.test(env.CLOUDFLARE_ACCOUNT_ID??'')||
      !isAbsolute(env.CLOUDFLARE_AI_TOKEN_FILE??''))throw new Error('configuration_invalid');
  const info=await metadata(env.CLOUDFLARE_AI_TOKEN_FILE);
  if(!info.isFile()||(info.mode&0o077)!==0||info.size>4096)throw new Error('configuration_invalid');
  const key=(await read(env.CLOUDFLARE_AI_TOKEN_FILE,'utf8')).trim();
  if(!/^[A-Za-z0-9_-]{20,4096}$/.test(key))throw new Error('configuration_invalid');
  return {...env,AI_PROVIDER:'cloudflare',AI_RECIPIENT:'Cloudflare Workers AI',
    AI_ENDPOINT:`https://api.cloudflare.com/client/v4/accounts/${env.CLOUDFLARE_ACCOUNT_ID}/ai/v1/chat/completions`,
    AI_IMAGE_MODEL:'@cf/google/gemma-4-26b-a4b-it',AI_OUTFIT_MODEL:'@cf/meta/llama-3.3-70b-instruct-fp8-fast',
    // The recommendation model supports JSON Mode. Two bounded calls (including
    // the one permitted JSON repair) must fit inside the worker's 45s deadline.
    AI_API_KEY:key,AI_MAX_OUTPUT_TOKENS:'1024',AI_TIMEOUT_MS:'30000',AI_OUTFIT_TIMEOUT_MS:'15000',
    AI_RUNTIME_MODULE:new URL('./runtime.mjs',import.meta.url).pathname};
}
export async function cloudflareResponse({env=process.env,stdin=process.stdin}={}) {
  try {return await adapterResponse({env:await cloudflareEnvironment(env),stdin});}
  catch{return {outcome:'permanent'};}
}
if(process.argv[1]&&import.meta.url===pathToFileURL(resolve(process.argv[1])).href) {
  process.stdout.write(JSON.stringify(await cloudflareResponse())+'\n');
}
