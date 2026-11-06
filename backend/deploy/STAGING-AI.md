> For persistent photo recognition, use [IMAGE-AI.md](IMAGE-AI.md). The workflow below is the original text-only smoke deployment.

# T027: bounded staging recommendation worker

The staging gateway can enqueue recommendations, but it does not execute them.
This deployment adds a separate text-only worker. It does not enable AI, change
the provider disclosure, grant user consent, or start a service automatically.

1. Run `backend/tests/ai-worker-deployment.sh` with
   `AI_DEPLOYMENT_PG_TESTS=1` against a disposable PostgreSQL cluster. Never point
   that script at Neon or another shared database.
2. Apply `neon-ai-worker.sql` in one transaction as the target database owner.
   Provision a dedicated LOGIN NOINHERIT role with membership only in
   `szafa_ai_worker`; do not reuse a gateway or owner credential.
3. Install the merged backend in `/opt/moja-szafa-ai-staging`. Keep its libpq
   connection settings in root-only `/etc/moja-szafa/ai-staging.env`.
   Use `PGSSLMODE=verify-full`, the system CA bundle, `AI_RUNTIME_ENABLED=true`,
   `CLOUDFLARE_WORKERS_PLAN=free`, and the existing account ID. The service loads
   the root-only Cloudflare token as a systemd credential, never from Git.
4. Install `moja-szafa-ai-staging.service` without enabling it at boot. Run its
   preflight with `--check-only` first. It rejects broad database roles, vision,
   unsupported queued jobs and budgets above 10 global / 4 per user per day.
5. For a real test, sign in through the hosted email flow, upload synthetic
   wardrobe items, review the exact provider disclosure and explicitly grant
   consent through the app. Only then enable text AI, enqueue a recommendation
   and manually start the service. It stops after 90 seconds and never restarts.
6. Record the authenticated result, provider-call receipt and elapsed time.
   Always disable AI and stop the service after the test, including failures.
   Confirm both policy switches are false and no worker remains running.

The database claim function refuses non-outfit work and is inaccessible to
consumer roles. The worker cannot change policy, consent, enqueue jobs, read
profile tables, or use the general queue-claim function. Photo recognition is
deliberately outside this text-only service; photo upload/sync/cleanup can be
verified independently without sending photos to an AI provider.

Text recommendations use `@cf/meta/llama-3.3-70b-instruct-fp8-fast`, listed in
[Cloudflare's supported JSON Mode models](https://developers.cloudflare.com/workers-ai/features/json-mode/).
The previous FP8 variant returned invalid JSON during a real staging test.
Each text request has a 15-second deadline, leaving time for the single allowed
JSON repair within the worker's unchanged 45-second adapter deadline. Image
requests retain their 30-second deadline. These settings do not raise quotas,
enable a paid plan, or establish successful live AI acceptance; verify a real
result before marking that gate complete. Preserve failed dispatch receipts.

Rollback: stop the service and set both AI policy switches to false. Preserve
jobs, dispatch receipts and accounting; an already dispatched call can finish
within its existing deadline. Do not drop application migrations or revoke
unrelated roles.
