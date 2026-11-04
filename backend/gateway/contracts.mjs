import {readFile,readdir} from 'node:fs/promises';
export async function loadRPCOperations(directory=new URL('../api/',import.meta.url)) {
  const files=(await readdir(directory)).filter(name=>/^openapi-(?:[a-z0-9]+-)*v1\.json$/.test(name)).sort();
  if(!files.includes('openapi-v1.json'))throw new Error('core_contract_required');
  const operations=new Set();
  for(const file of files) {
    const contract=JSON.parse(await readFile(new URL(file,directory),'utf8'));
    if(contract.openapi!=='3.1.0'||!contract.paths||Array.isArray(contract.paths)||typeof contract.paths!=='object')throw new Error('invalid_contract');
    for(const [path,route] of Object.entries(contract.paths)) {
      const operation=route?.post?.operationId;
      if(typeof operation!=='string'||!/^api_v1_[a-z_]+$/.test(operation)||path!==`/rest/v1/rpc/${operation}`||operations.has(operation))throw new Error('invalid_or_duplicate_rpc');
      operations.add(operation);
    }
  }
  return [...operations];
}
