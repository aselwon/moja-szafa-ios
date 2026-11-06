# Encrypted paired backups

`paired-backup.py` creates and verifies a single encrypted database/photo recovery
set. It does not schedule backups, stop services, execute restored SQL, or authorize
reopening. Follow the [T055 recovery gates](../../docs/operations/T055-backup-restore.md)
for identity recovery, deletion replay, privileges, retention and cutover.

Requirements: Python 3.9+, compatible PostgreSQL client tools and the standard
[age CLI](https://github.com/FiloSottile/age). Use a direct database connection,
not a transaction pooler. Configure a named libpq service in a private service
file and credentials through libpq/secret management. Never pass credentials as
arguments. The dump retains ownership and ACL statements; cluster roles and
provider-managed identity/configuration require separate recovery procedures.

Generate an age identity on the recovery host and store it separately from backups
and the source server. Only its public recipient file is needed during capture.
Test key recovery before depending on the archives. Use a private, encrypted
filesystem for temporary plaintext and enough free capacity for the database,
photo copy, tar and encrypted archive. Ordinary errors clean temporary files;
abrupt machine/process failure can leave private temporary directories. Unlinking
files is not secure erasure on SSDs.

## Capture

Fence and drain **all** database, upload and cleanup writers first. Keep them
stopped until the command returns. The `--writers-stopped` flag records an operator
assertion; it does not stop writers or prove that an external provider has stopped
writing. Photo metadata checks detect changes during capture, but cannot establish
consistency against arbitrary unfenced writers.

```sh
umask 077
mkdir -m 700 /private/backup-output
python3 backend/recovery/paired-backup.py capture \
  --service szafa_backup --objects /private/frozen-photo-volume \
  --recipients /private/recovery-recipients.txt \
  --output /private/backup-output/recovery-set.age --writers-stopped
```

The output parent must already exist with private permissions (0700). It must be
outside the photo source. The tool takes a real custom-format dump, validates its
TOC, rejects missing/empty photo files referenced by ready image rows, copies every
photo file (including cleaned variants), records per-file SHA-256
and size in an encrypted manifest, encrypts the tar, and publishes atomically
without replacing an existing archive. Detected source changes, links and special
files fail capture. Failure before publication leaves no final archive.

Save the returned encrypted-archive SHA-256 in a trusted separate receipt. Age
encryption alone does not authenticate who created the archive. The aggregate
receipt contains no private identifiers, photo names, credentials or URLs.

## Unpack on an isolated recovery host

```sh
python3 backend/recovery/paired-backup.py unpack \
  --archive /private/backup-output/recovery-set.age \
  --identity /separate/private/recovery-identity.txt \
  --sha256 <trusted-receipt-sha256> --output /private/recovery-new
```

Use a private mode-0700 output parent and a mode-0600 native age identity file.
Unpacking refuses an existing destination, checks the outer digest, completes
authenticated decryption, rejects absolute/traversal/duplicate/link entries, and
verifies every manifest checksum and the exact file inventory. Failure removes
only its newly created output directory. `VERIFIED.json` leaves `database_restored`,
`deletion_replay_completed` and `safe_to_reopen` false.

Continue with the isolated SQL restore, privilege checks and independent deletion
replay. Never point a live gateway at unpacked photos before those checks. The
tool cannot revoke external sessions, recover provider identities, or obtain the
post-backup deletion journal. A successful unpack is not completed recovery.

## Verification

```sh
python3 -m unittest discover -s backend/recovery -p 'test_paired_backup.py'
bash backend/tests/recovery-drill.sh
```

The first suite exercises real age encryption/decryption, tampering, wrong keys,
unsafe tar entries, manifest corruption, destination preservation and detected
source mutation. The PostgreSQL drill uses the real capture/unpack commands on
generated data, then restores SQL, replays later deletions twice, and verifies
remaining bytes. These are synthetic fixtures, not production RPO/RTO evidence.
