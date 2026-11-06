import { execFile } from 'node:child_process';
import { isAbsolute,resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { access } from 'node:fs/promises';
import { cloudflareEnvironment } from '../ai/cloudflare-adapter.mjs';

export function deploymentQuery(env) {
  const sql=`SELECT jsonb_build_object('role_allowed',current_user='szafa_ai_worker' AND EXISTS(
    SELECT FROM pg_roles g WHERE g.rolname=current_user AND NOT g.rolcanlogin AND NOT g.rolinherit
      AND NOT g.rolsuper AND NOT g.rolbypassrls AND NOT g.rolcreatedb AND NOT g.rolcreaterole) AND EXISTS(
    SELECT FROM pg_roles r WHERE r.rolname=session_user AND NOT r.rolinherit AND NOT r.rolsuper AND NOT r.rolbypassrls AND NOT r.rolcreatedb AND NOT r.rolcreaterole
      AND pg_has_role(session_user,'szafa_ai_worker','MEMBER')
      AND NOT pg_has_role(session_user,'service_role','MEMBER')
      AND NOT EXISTS(SELECT FROM pg_roles g WHERE g.rolname='szafa_gateway' AND pg_has_role(session_user,g.oid,'MEMBER'))
      AND NOT EXISTS(SELECT FROM pg_database WHERE datdba=r.oid)),
    'policy',app.ai_worker_readiness());`;
  return new Promise((resolveResult,reject)=>{
    const child=execFile('psql',['-XqAt','-v','ON_ERROR_STOP=1'],{env,timeout:15000,maxBuffer:16384},(error,stdout)=>{
      if(error)return reject(new Error('worker_preflight_failed'));
      try{resolveResult(JSON.parse(stdout));}catch{reject(new Error('worker_preflight_failed'));}
    });
    child.stdin.on('error',()=>{});child.stdin.end(sql);
  });
}
export async function workerPreflight(env,{query=deploymentQuery,requireEnabled=true,provider=cloudflareEnvironment,checkCA=access}={}) {
  if(!env.PGHOST?.endsWith('.neon.tech') || env.PGSSLMODE!=='verify-full' || !isAbsolute(env.PGSSLROOTCERT??'') ||
    env.AI_WORKER_OUTFIT_ONLY!=='true' || !env.PGUSER || !env.PGPASSWORD || !env.PGDATABASE || !isAbsolute(env.PRIVATE_IMAGE_DIRECTORY??'') ||
    (requireEnabled && env.AI_RUNTIME_ENABLED!=='true'))throw new Error('worker_preflight_failed');
  await checkCA(env.PGSSLROOTCERT);
  await provider(env); // Validate private free-plan credentials; makes no inference call.
  const result=await query(env),p=result?.policy;
  if(result?.role_allowed!==true || !p || p.image_enabled!==false || p.unsupported_jobs_pending!==false ||
    p.recipient!=='Cloudflare Workers AI' || !Number.isInteger(p.daily_user_units) || p.daily_user_units<1 || p.daily_user_units>4 ||
    !Number.isInteger(p.daily_global_units) || p.daily_global_units<1 || p.daily_global_units>10 ||
    (requireEnabled && (p.enabled!==true || p.disclosure_matches!==true)))throw new Error('worker_preflight_failed');
  return {role_allowed:true,enabled:p.enabled,image_enabled:false,disclosure_matches:p.disclosure_matches};
}
if(process.argv[1] && import.meta.url===pathToFileURL(resolve(process.argv[1])).href) {
  workerPreflight(process.env,{requireEnabled:!process.argv.includes('--check-only')})
    .then(result=>process.stdout.write(JSON.stringify(result)+'\n'))
    .catch(()=>{process.stderr.write('worker_preflight_failed\n');process.exitCode=1;});
}
