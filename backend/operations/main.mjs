import { Pool } from 'pg';
import { fileURLToPath } from 'node:url';
import { OperatorAuth, operatorConfiguration } from './auth.mjs';
import { OperatorStore } from './store.mjs';
import { createOperatorServer } from './server.mjs';

export async function main(env=process.env) {
  const configuration=operatorConfiguration(env);
  if(!configuration || !env.OPS_DATABASE_URL) throw new Error('operations_configuration_missing');
  const port=Number(env.OPS_PORT??18082);
  if(!Number.isInteger(port)||port<1024||port>65535) throw new Error('operations_port_invalid');
  let gatewayURL;
  if(env.OPS_GATEWAY_HEALTH_URL) {
    gatewayURL=new URL(env.OPS_GATEWAY_HEALTH_URL);
    if(gatewayURL.protocol!=='http:'||gatewayURL.hostname!=='127.0.0.1'||gatewayURL.pathname!=='/health'||
      gatewayURL.username||gatewayURL.password||gatewayURL.search||gatewayURL.hash||Number(gatewayURL.port)===port) throw new Error('operations_health_url_invalid');
  }
  const pool=new Pool({connectionString:env.OPS_DATABASE_URL,max:4,connectionTimeoutMillis:5000,query_timeout:7000});
  try {
    const {rows}=await pool.query(`SELECT NOT r.rolsuper AND NOT r.rolbypassrls AND NOT r.rolinherit
      AND pg_has_role(current_user,'szafa_ops','MEMBER')
      AND NOT pg_has_role(current_user,'service_role','MEMBER') AS safe
      FROM pg_roles r WHERE r.rolname=current_user`);
    if(rows[0]?.safe!==true) throw new Error('operations_database_role_invalid');
    const server=createOperatorServer({auth:new OperatorAuth(configuration),store:new OperatorStore(pool),origin:configuration.origin,
      health:async()=>{
        if(!gatewayURL)return {gateway:'not_configured'};
        try {
          const result=await fetch(gatewayURL,{signal:AbortSignal.timeout(2000),redirect:'error'});
          await result.body?.cancel();
          return {gateway:result.status===200?'reachable':'unhealthy'};
        } catch {return {gateway:'unreachable'};}
      }});
    server.on('close',()=>{void pool.end();});
    await new Promise((resolve,reject)=>{server.once('error',reject);server.listen(port,'127.0.0.1',resolve);});
    return server;
  } catch(error) {await pool.end();throw error;}
}
if(process.argv[1]===fileURLToPath(import.meta.url)) main().then(server=>{
  const stop=()=>{server.close();server.closeAllConnections();};
  process.once('SIGTERM',stop);process.once('SIGINT',stop);
}).catch(()=>{process.stderr.write('operations_startup_failed\n');process.exitCode=1;});
