# Bounded staging capture runner

`backup-runner.py` coordinates the existing encrypted paired database/photo
capture. It is not enabled by checking in the service/timer templates. A local
verified ciphertext is not an off-host backup or proof of operational RPO/RTO.

The root-only JSON config has exactly these fields:

```json
{
  "service": "szafa_backup_staging",
  "service_file": "/etc/moja-szafa/backup.pg_service.conf",
  "objects": "/var/lib/moja-szafa-gateway-staging/images",
  "recipients": "/etc/moja-szafa/backup-recipients.txt",
  "output": "/var/lib/moja-szafa-backups",
  "writer_units": ["moja-szafa-gateway-staging.service", "moja-szafa-ai-staging.service"],
  "health_urls": ["http://127.0.0.1:18083/health"],
  "lease_seconds": 180,
  "capture_seconds": 90,
  "max_file_bytes": 268435456,
  "reserve_bytes": 1073741824
}
```

Provision the approved target's libpq connection outside Git. Require verified
TLS and a read-only backup identity with sufficient access to every captured
table; do not reuse the consumer or AI worker identity. Only public age
recipients belong on the capture host. Keep private recovery identities off
that host, separate from ciphertext, and verify their custody and restore use.
The config/service file/output directory must be private and root-owned.
Install compatible PostgreSQL clients and age from the operating system's
package registry. Verify the actual writer inventory before enabling a schedule;
every service able to change this database or photo directory must be fenced.

The runner takes a nonblocking lock, checks disk space and stable service states,
then arms an independent systemd resume timer **before** stopping active writers.
It refuses a pair if a writer restarts or the capture approaches the lease end.
It resumes only previously active writers: an inactive AI worker stays inactive.
Capture failures still resume writers. A failed resume/health check leaves the
watchdog armed. Killing the runner does not cancel that independent watchdog.
The fixed capture deadline kills the full child process group on timeout.

After resume, the runner verifies the encrypted archive hash/size, publishes it
without replacement and writes a private receipt plus `status.json`. Errors
preserve the previous success and emit bounded error codes instead of database
credentials or subprocess stderr. No old backup is automatically deleted.
Insufficient disk space prevents a new freeze/capture, so operators must act on
failed/stale status before capacity is exhausted.

The supplied timer proposes 03:00 and 15:00 UTC plus up to five minutes of jitter.
Enable only after a manual run/restore and the target, maintenance interruption,
off-host replication, retention and monitoring configuration are reviewed.
Each capture briefly interrupts staging writers. The timer alone does not meet
the 24-hour off-host RPO: an awake/online replica, verified transfer and stale
backup monitoring are also required. Retention must account for deletion
journals; never purge those markers while older recoverable backups remain.

Before declaring T055 complete, perform a populated paired restore into an
isolated target, replay the retained deletion journal before exposing data,
verify provider-managed identity recovery separately, and measure actual RPO
and RTO. Existing synthetic drills do not substitute for these operational gates.

Run the coordinator failure tests with:
`python3 -m unittest discover -s backend/recovery -p 'test_backup_runner.py'`.
They cover resume behavior, inactive AI, watchdog failure, timeout, premature
writer restart, bad ciphertext, low disk space and concurrent capture rejection.
