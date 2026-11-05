#!/usr/bin/env bash
# Synthetic rehearsal ONLY, on a disposable test cluster using libpq settings.
# No destination argument, production dump, network storage or customer data.
set -euo pipefail
umask 077
root=$(cd "$(dirname "$0")/.." && pwd)
for tool in psql createdb dropdb pg_dump pg_restore python3; do
    command -v "$tool" >/dev/null || { echo "Required recovery tool missing: $tool" >&2; exit 1; }
done
prefix="wardrobe_t055_${$}_${RANDOM}"
source_db="${prefix}_source"
restore_db="${prefix}_restore"
artifacts=$(mktemp -d)
source_created=false
restore_created=false
cleanup() {
    if $source_created; then dropdb --if-exists "$source_db"; fi
    if $restore_created; then dropdb --if-exists "$restore_db"; fi
    rm -rf "$artifacts"
}
trap cleanup EXIT
createdb "$source_db"
source_created=true
psql -X -v ON_ERROR_STOP=1 -d "$source_db" -f "$root/tests/bootstrap.sql" >/dev/null
bash "$root/migrate.sh" "$source_db" >/dev/null
psql -X -v ON_ERROR_STOP=1 -d "$source_db" -f "$root/tests/recovery-fixture.sql" >/dev/null
# Frozen synthetic source: database and object bytes share this recovery point.
python3 - "$artifacts" <<'PY'
import pathlib, sys, time
p = pathlib.Path(sys.argv[1])
(p / 'recovery-point').write_text(str(time.time()))
for n in range(1, 4):
    folder = p / 'objects' / f'30000000-0000-0000-0000-00000000000{n}'
    folder.mkdir(parents=True)
    for variant in ('original', 'thumbnail'):
        (folder / f'{variant}.jpg').write_bytes(f'synthetic-byte-fixture-{n}-{variant}'.encode())
PY
pg_dump --format=custom --file="$artifacts/database.dump" "$source_db"
cp -R "$artifacts/objects" "$artifacts/object-backup"
# Independent deletion evidence created AFTER the snapshot, not restored from it.
cat > "$artifacts/deletions.sql" <<'SQL'
CREATE TEMP TABLE recovery_accounts(user_id uuid PRIMARY KEY);
CREATE TEMP TABLE recovery_garments(user_id uuid, garment_id uuid, PRIMARY KEY(user_id,garment_id));
INSERT INTO recovery_accounts VALUES ('10000000-0000-0000-0000-000000000001');
INSERT INTO recovery_garments VALUES
('10000000-0000-0000-0000-000000000002','20000000-0000-0000-0000-000000000002'),
-- A deleted offline draft created after the backup must also remain fenced.
('10000000-0000-0000-0000-000000000002','20000000-0000-0000-0000-000000000004'),
-- Wrong owner must not delete the surviving garment.
('10000000-0000-0000-0000-000000000002','20000000-0000-0000-0000-000000000003');
SQL
psql -X -v ON_ERROR_STOP=1 --single-transaction -d "$source_db" \
    -f "$artifacts/deletions.sql" -f "$root/recovery/replay-deletions.sql" >/dev/null
python3 - "$artifacts" <<'PY'
import pathlib, sys, time
(pathlib.Path(sys.argv[1]) / 'incident-start').write_text(str(time.time()))
PY
createdb "$restore_db"
restore_created=true
# Newer pg_restore clients emit settings (e.g. transaction_timeout) unknown to
# older servers; drop them so the drill works across client/server versions.
pg_restore --file=- "$artifacts/database.dump" \
    | sed '/^SET transaction_timeout = /d' \
    | psql -X -q -v ON_ERROR_STOP=1 --single-transaction -d "$restore_db" >/dev/null
cp -R "$artifacts/object-backup" "$artifacts/restored-objects"
# Prove that restore really brought back the now-deleted rows before replay.
psql -X -v ON_ERROR_STOP=1 -d "$restore_db" <<'SQL' >/dev/null
DO $$ BEGIN
    IF (SELECT count(*) FROM app.garments) <> 3 OR (SELECT count(*) FROM auth.users) <> 3 THEN
        RAISE EXCEPTION 'Snapshot did not restore the expected pre-deletion state';
    END IF;
END $$;
SQL
for attempt in 1 2; do
    psql -X -v ON_ERROR_STOP=1 --single-transaction -d "$restore_db" \
        -f "$artifacts/deletions.sql" -f "$root/recovery/replay-deletions.sql" \
        -f "$root/tests/recovery-verify.sql" >/dev/null
done
psql -X -v ON_ERROR_STOP=1 -At -d "$restore_db" \
    -c "SELECT id FROM api_private.image_uploads WHERE state = 'retired' ORDER BY id" > "$artifacts/retired-uploads"
python3 - "$artifacts" <<'PY'
import hashlib, json, pathlib, shutil, sys, time, uuid
p = pathlib.Path(sys.argv[1])
restored = p / 'restored-objects'
# Exercise repeatable byte erasure independently of cascading database rows.
for attempt in range(2):
    for entry in (p / 'retired-uploads').read_text().splitlines():
        key = str(uuid.UUID(entry))
        target = restored / key
        if target.exists():
            shutil.rmtree(target)
expected = p / 'object-backup' / '30000000-0000-0000-0000-000000000003'
files = sorted(restored.rglob('*.jpg'))
assert len(files) == 2, 'Deleted bytes survived or survivor bytes were lost'
for file in files:
    assert file.parent.name == expected.name
    assert hashlib.sha256(file.read_bytes()).digest() == hashlib.sha256((expected / file.name).read_bytes()).digest()
incident = float((p / 'incident-start').read_text())
rpo = incident - float((p / 'recovery-point').read_text())
rto = time.time() - incident
assert 0 <= rpo <= 24 * 3600, 'Synthetic RPO exceeded target'
assert 0 <= rto <= 8 * 3600, 'Synthetic RTO exceeded target'
print(json.dumps({'scope': 'synthetic local rehearsal, not production evidence',
                  'rpo_seconds': rpo, 'rto_seconds': rto,
                  'deletion_replays': 2, 'surviving_objects': len(files)}))
PY
