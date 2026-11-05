import { createServer } from 'node:http';
import { randomUUID } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import { OperatorError } from './auth.mjs';
import { estimateAICost } from '../observability/ai-cost.mjs';

const UUID = /^[a-f0-9]{8}(-[a-f0-9]{4}){3}-[a-f0-9]{12}$/i;
const actions = new Set(['summary','support_list','support_read','support_update','policy_update','audit_list']);
const staticFiles = new Map([['/', ['index.html','text/html; charset=utf-8']], ['/panel.js',['panel.js','text/javascript; charset=utf-8']],
  ['/panel.css',['panel.css','text/css; charset=utf-8']]]);

async function body(request) {
  if (request.headers['content-type']?.split(';')[0] !== 'application/json') throw new OperatorError('invalid_request',400);
  let bytes=0; const chunks=[];
  for await (const chunk of request) {
    bytes+=chunk.length; if(bytes>4096) throw new OperatorError('invalid_request',413);
    chunks.push(chunk);
  }
  let value; try { value=JSON.parse(Buffer.concat(chunks).toString('utf8')); } catch { throw new OperatorError('invalid_request',400); }
  if(!value || Array.isArray(value) || !actions.has(value.action)) throw new OperatorError('invalid_request',400);
  return value;
}

export function createOperatorServer({ auth, store, origin, health = async () => ({ gateway:'not_configured' }), now=Date.now }) {
  if (!auth || !store || new URL(origin).protocol!=='https:') throw new Error('operations_configuration_missing');
  const clients=new Map(); let active=0;
  const server=createServer(async (request,response)=>{
    const headers={ 'Cache-Control':'no-store', 'X-Content-Type-Options':'nosniff', 'Referrer-Policy':'no-referrer',
      'Content-Security-Policy':"default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'",
      'X-Frame-Options':'DENY', 'Permissions-Policy':'camera=(), microphone=(), geolocation=()' };
    const send=(status,value)=>{ response.writeHead(status,{...headers,'Content-Type':'application/json'}); response.end(JSON.stringify(value)); };
    if(active>=8) return send(503,{error:{code:'busy'}});
    active++;
    try {
      if(request.headers['sec-fetch-site']==='cross-site' || (request.headers.origin && request.headers.origin!==origin)) throw new OperatorError('origin_denied',403);
      const url=new URL(request.url,origin);
      if(url.origin!==origin || url.search) throw new OperatorError('not_found',404);
      const address=request.socket.remoteAddress; // Never trust caller-forwarded IPs.
      for(const [key,value] of clients) if(value.until<=now()) clients.delete(key);
      const limit=clients.get(address)??{count:0,until:now()+60000};
      if(limit.count>=120 || (!clients.has(address)&&clients.size>=1000)) throw new OperatorError('rate_limited',429);
      limit.count++; clients.set(address,limit);
      // The MFA-capable SSO proxy supplies an access token on every request.
      // An arbitrary proxy identity header or consumer cookie is never trusted.
      const header=request.headers.authorization;
      if(typeof header!=='string'||!header.startsWith('Bearer ')) throw new OperatorError('operator_authentication_required');
      const actor=await auth.authenticate(header.slice(7));
      if(request.method==='GET'&&staticFiles.has(url.pathname)) {
        // Also enforce current operator registration/revocation before UI access.
        const access=await store.command(actor,randomUUID(),{action:'summary'});
        if(access.error) throw new OperatorError('operator_denied',403);
        const [file,type]=staticFiles.get(url.pathname);
        const content=await readFile(new URL(`./public/${file}`,import.meta.url));
        response.writeHead(200,{...headers,'Content-Type':type}); return response.end(content);
      }
      if(request.method!=='POST'||url.pathname!=='/api/command') throw new OperatorError('not_found',404);
      if(request.headers.origin!==origin) throw new OperatorError('origin_denied',403);
      const requestID=request.headers['idempotency-key'];
      if(typeof requestID!=='string'||!UUID.test(requestID)) throw new OperatorError('invalid_request',400);
      const command=await body(request);
      const result=await store.command(actor,requestID,command);
      if(result.error) {
        const statuses={ operator_denied:403,version_conflict:409,idempotency_conflict:409,request_already_used:409,not_found:404,policy_limit:422,policy_unavailable:503,invalid_request:400 };
        return send(statuses[result.error.code]??503,result);
      }
      if(command.action==='summary') {
        result.data.cost=estimateAICost(result.data.aiCalls??[]);
        result.data.services=await health();
      }
      send(200,result);
    } catch(error) {
      send(error instanceof OperatorError?error.status:503,{error:{code:error instanceof OperatorError?error.code:'operations_unavailable'}});
    } finally {active--;}
  });
  server.headersTimeout=10000; server.requestTimeout=15000; server.keepAliveTimeout=5000;
  return server;
}
