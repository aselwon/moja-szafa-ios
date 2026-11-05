import { isAbsolute } from 'node:path';
import { access } from 'node:fs/promises';
import { privateFiles } from '../images/pipeline.mjs';
import { neonErasureStore } from './adapters/neon-store.mjs';
import { neonIdentity, privateManagementKey } from './adapters/neon-identity.mjs';
import { privateAccountStorage } from './adapters/private-storage.mjs';
import { replicatedDeletionJournal } from './adapters/replicated-journal.mjs';

async function configure(env) {
  if(env.ERASURE_RUNTIME_ENABLED!=='true' || !env.DATABASE_URL ||
    !['PRIVATE_IMAGE_DIRECTORY','EXPORT_DIRECTORY','ERASURE_JOURNAL_DIRECTORY','ERASURE_ACK_DIRECTORY','NEON_MANAGEMENT_KEY_FILE','PGSSLROOTCERT'].every(name=>isAbsolute(env[name]??'')))throw new Error();
  await access(env.PGSSLROOTCERT);
  const key=await privateManagementKey(env.NEON_MANAGEMENT_KEY_FILE);
  const store=neonErasureStore({connectionString:env.DATABASE_URL,sslRootCert:env.PGSSLROOTCERT});
  await store.verifyRole();
  const identity=neonIdentity({project:env.NEON_PROJECT_ID,branch:env.NEON_BRANCH_ID,key,store});
  const storage=privateAccountStorage({images:privateFiles(env.PRIVATE_IMAGE_DIRECTORY),exportDirectory:env.EXPORT_DIRECTORY,store});
  const backups=replicatedDeletionJournal({directory:env.ERASURE_JOURNAL_DIRECTORY,acknowledgementDirectory:env.ERASURE_ACK_DIRECTORY,
    replica:env.ERASURE_REPLICA_ID,assertLease:store.assertLease});
  return {store,identity,storage,backups};
}

// Operator module for: node backend/deletion/worker.mjs backend/deletion/neon-runtime.mjs
// Configuration errors never expose a connection string, provider key or cause.
const runtime=await configure(process.env).catch(()=>{throw new Error('erasure_runtime_configuration_required');});
export const {store,identity,storage,backups}=runtime;
