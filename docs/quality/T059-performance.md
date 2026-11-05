# T059 preliminary database benchmark

## Scope

`backend/tests/performance.sql` is a preliminary, local PostgreSQL benchmark for
wardrobe and wear-history RPC functions. It records raw samples and response
sizes. The database guard requires a database named `szafa_benchmark_*` with no
profiles and runs the synthetic workload inside a transaction that is rolled
back. The raw samples are preserved in
[`evidence/T059-database-baseline.csv`](evidence/T059-database-baseline.csv).

This is database-only timing of each function call, including its JSON result
construction. It is not the end-to-end text API p95 <=800 ms gate, and it says
nothing about warm launch p95 <=2 s, AI p95 <=30 s, or beta crash-free sessions.
Physical device, OS, network, and staging conditions are still unresolved, so
this preliminary run cannot close T059 acceptance.

## Workload and measurements

The fixture creates one synthetic owner, 1,000 synthetic garments, 1,826 wear
events across `[2021-01-01, 2026-01-01)` (five calendar years, including leap
day), and 9,130 event-to-garment rows (five garment memberships per event).
IDs, dates, item assignment, and `Europe/Warsaw` timezone are deterministic.
The SQL checks these row counts before measuring.

It measures four authenticated database functions:

- `wardrobe_first_page`: first 40 garments
- `wardrobe_last_page`: final page starting at offset 960
- `garment_detail`: one garment detail
- `sync_snapshot`: full owner snapshot including wear history

Each function runs five excluded warmups followed by 100 timed samples. The
CSV contains every timed sample (`operation`, `iteration`, `elapsed_ms`, and
`response_bytes`). The summarizer validates all 400 rows and reports
nearest-rank p50, p95, maximum duration and maximum response size for each
operation. For 100 samples, p95 is the 95th sorted value (one-based).

## Preliminary result (2026-11-05)

This run used revision `00e71e1` plus the uncommitted benchmark fixture and
summarizer, with migrations 001 through 025 applied. PostgreSQL 15.19 ran in a
Debian aarch64 Docker container on a MacBookPro18,2 host (10 CPU cores, 32 GiB
host memory; Docker reports 7.75 GiB available and no explicit container CPU
or memory limit). The measured calls ran locally inside PostgreSQL; no
external-network latency was included.

| Operation | Samples | p50 (ms) | p95 (ms) | Max (ms) | Max response (bytes) |
| --- | ---: | ---: | ---: | ---: | ---: |
| Garment detail | 100 | 0.318 | 0.498 | 0.773 | 499 |
| Wardrobe first page | 100 | 2.995 | 3.280 | 3.462 | 10,446 |
| Wardrobe last page | 100 | 15.052 | 17.696 | 24.996 | 10,448 |
| Sync snapshot | 100 | 55.326 | 66.933 | 89.116 | 1,122,216 |

All 400 samples passed the summarizer's validation. The fixture transaction
rolled back to zero synthetic rows, and the disposable database was dropped.
These are preliminary database-only results; they do not establish the
end-to-end text API p95 <=800 ms gate, warm-launch p95 <=2 s, AI p95 <=30 s, or
beta crash-free-session target. Device, OS, network profile, and staging
conditions remain unresolved, so this run is not final T059 acceptance.

## Reproduction

Run from the repository root with local PostgreSQL 15 tools and a disposable
local database, using a local PostgreSQL connection profile only. Ensure the
`createdb` and `psql` libpq settings target that local cluster; do not use
remote development, staging, or production connection settings. This script
makes no HTTP, provider, or paid-service calls. Bootstrap creates the test
roles and local `auth` schema; the migration command applies the checked-in
schema. The SQL fixture rejects a non-prefixed database and any database that
already contains profiles.

```sh
set -euo pipefail
benchmark_db="szafa_benchmark_$(date -u +%Y%m%dT%H%M%SZ)_$$"
results_file="/tmp/${benchmark_db}.csv"
createdb "$benchmark_db"
trap 'dropdb --if-exists "$benchmark_db"' EXIT
psql -X -v ON_ERROR_STOP=1 -d "$benchmark_db" \
  -f backend/tests/bootstrap.sql
bash backend/migrate.sh "$benchmark_db"
psql -X -q -v ON_ERROR_STOP=1 -d "$benchmark_db" \
  -f backend/tests/performance.sql > "$results_file"
python3 scripts/summarize-performance.py "$results_file" \
  > "${results_file%.csv}.summary.json"
printf 'Raw samples: %s\nSummary: %s\n' "$results_file" "${results_file%.csv}.summary.json"
```

The SQL transaction rolls back its synthetic user, garments, events, event
items, and temporary measurements. The disposable database is then dropped by
the shell trap. Preserve the raw CSV alongside any later summary; do not
substitute these measurements for physical-device, network, API, AI, or
reliability evidence.
