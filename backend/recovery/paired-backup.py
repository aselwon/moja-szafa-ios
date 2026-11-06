#!/usr/bin/env python3
"""Encrypted, paired recovery artifacts. Never starts/stops writers or restores SQL.

The operator must fence and drain ALL database/photo writers before capture, and
keep them fenced until capture returns. The flag records that explicit contract;
it cannot prove that an external process or provider has stopped writing.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import stat
import subprocess
import tarfile
import tempfile


class BackupError(Exception):
    pass


def utc():
    return datetime.now(timezone.utc).isoformat()


def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as source:
        for block in iter(lambda: source.read(1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()


def run(command, **kwargs):
    # Provider diagnostics can contain passwords, URLs or private object paths.
    result = subprocess.run(command, stdin=subprocess.DEVNULL,
                            stderr=subprocess.DEVNULL, **kwargs)
    if result.returncode:
        raise BackupError(command[0] + ' failed; no recovery artifact published')
    return result


def inventory(root):
    if root.is_symlink() or not root.is_dir():
        raise BackupError('Photo source must be a real directory')
    entries = {}
    for directory, dirs, files in os.walk(root, followlinks=False):
        for name in sorted(dirs + files):
            path = Path(directory) / name
            info = path.lstat()
            if not stat.S_ISREG(info.st_mode) and not stat.S_ISDIR(info.st_mode):
                raise BackupError('Photo source contains a link or special file')
            if stat.S_ISREG(info.st_mode) and info.st_nlink != 1:
                raise BackupError('Photo source contains a hard link')
            entries[path.relative_to(root).as_posix()] = (
                info.st_dev, info.st_ino, info.st_mode, info.st_size,
                info.st_mtime_ns, info.st_ctime_ns)
    return entries


def private_parent(path):
    parent = path.parent.resolve(strict=True)
    if not parent.is_dir() or parent.stat().st_mode & 0o077:
        raise BackupError('Output parent must be a private directory (mode 0700)')
    return parent


def capture(args):
    if not args.writers_stopped:
        raise BackupError('Fence and drain all database/photo writers first')
    if not re.fullmatch(r'[A-Za-z0-9_-]{1,64}', args.service):
        raise BackupError('Use a libpq service name, never a connection URL')
    recipient = Path(args.recipients).read_text()
    keys = [line.strip() for line in recipient.splitlines()
            if line.strip() and not line.lstrip().startswith('#')]
    if not keys or any(not re.fullmatch(r'age1[0-9a-z]{58}', key) for key in keys):
        raise BackupError('Recipients must be native age public keys')
    output = Path(args.output).absolute()
    parent = private_parent(output)
    if output.exists() or output.is_symlink():
        raise BackupError('Output already exists')
    objects = Path(args.objects).absolute()
    # Keep staging and output outside the photo source, including symlink aliases.
    if objects.resolve() == parent or objects.resolve() in parent.parents:
        raise BackupError('Output must be outside the photo source')
    before = inventory(objects)
    recovery_point = utc()
    with tempfile.TemporaryDirectory(prefix='.paired-capture-', dir=parent) as tmp:
        stage = Path(tmp)
        payload = stage / 'payload'
        payload.mkdir(mode=0o700)
        dump = payload / 'database.dump'
        env = dict(os.environ, PGCONNECT_TIMEOUT='15')
        required = json.loads(run([
            'psql', '--no-password', '--dbname=service=' + args.service, '-X', '-At', '-v', 'ON_ERROR_STOP=1',
            '-c', "SELECT coalesce(json_agg(object_key ORDER BY object_key),'[]'::json) FROM ("
            "SELECT object_key FROM app.garment_images WHERE status='ready' UNION "
            "SELECT id::text || '/' || variant FROM api_private.image_uploads CROSS JOIN LATERAL "
            "unnest(CASE WHEN has_cleaned THEN ARRAY['original.jpg','thumbnail.jpg','cleaned.png'] "
            "ELSE ARRAY['original.jpg','thumbnail.jpg'] END) AS variant WHERE state='ready') AS keys"
        ], stdout=subprocess.PIPE, env=env).stdout)
        if not isinstance(required, list) or any(
            not isinstance(key, str) or not re.fullmatch(
                r'[a-f0-9-]{36}/(?:original\.jpg|thumbnail\.jpg|cleaned\.png)', key)
            for key in required):
            raise BackupError('Invalid ready-photo inventory')
        with dump.open('xb') as stream:
            run(['pg_dump', '--no-password', '--dbname=service=' + args.service, '--format=custom',
                 '--lock-wait-timeout=10s'], stdout=stream, env=env)
        # Validate the archive header/TOC before publishing; roles and ACLs remain
        # in the dump, rather than silently weakening a later recovery.
        run(['pg_restore', '--list', str(dump)], stdout=subprocess.DEVNULL)
        (payload / 'objects').mkdir(mode=0o700)
        files = {'database.dump': {'bytes': dump.stat().st_size, 'sha256': digest(dump)}}
        for name, signature in sorted(before.items()):
            source, target = objects / name, payload / 'objects' / name
            if stat.S_ISDIR(signature[2]):
                target.mkdir(mode=0o700, parents=True, exist_ok=True)
                continue
            target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            fd = os.open(source, os.O_RDONLY | os.O_NOFOLLOW)
            with os.fdopen(fd, 'rb') as incoming, target.open('xb') as outgoing:
                info = os.fstat(incoming.fileno())
                if (info.st_dev, info.st_ino, info.st_mode, info.st_size,
                    info.st_mtime_ns, info.st_ctime_ns) != signature:
                    raise BackupError('Photo source changed during capture')
                shutil.copyfileobj(incoming, outgoing, 1024 * 1024)
            files['objects/' + name] = {'bytes': target.stat().st_size, 'sha256': digest(target)}
        if inventory(objects) != before:
            raise BackupError('Photo source changed during capture')
        if any('objects/' + key not in files or files['objects/' + key]['bytes'] == 0
               for key in required):
            raise BackupError('A ready database photo is missing or empty')
        manifest = {'format': 'szafa-paired-backup-v1', 'recovery_point_at': recovery_point,
                    'captured_at': utc(), 'writers_stopped_asserted': True, 'files': files,
                    'database_service': args.service, 'required_photo_keys': required}
        (payload / 'manifest.json').write_text(json.dumps(manifest, sort_keys=True) + '\n')
        archive = stage / 'payload.tar'
        with tarfile.open(archive, 'w') as tar:
            for name in ['manifest.json'] + sorted(files):
                tar.add(payload / name, arcname=name, recursive=False)
        encrypted = stage / 'backup.age'
        validated_recipients = stage / 'recipients.txt'
        validated_recipients.write_text('\n'.join(keys) + '\n')
        run(['age', '--encrypt', '--recipients-file', str(validated_recipients),
             '--output', str(encrypted), str(archive)], stdout=subprocess.DEVNULL)
        with encrypted.open('rb') as stream:
            os.fsync(stream.fileno())
        checksum = digest(encrypted)
        # Atomic no-replace publication, including concurrent runs on this path.
        os.link(encrypted, output)
        directory_fd = os.open(parent, os.O_RDONLY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    return {'sha256': checksum, 'recovery_point_at': recovery_point,
            'object_files': len(files) - 1, 'encrypted_bytes': output.stat().st_size}


def unpack(args):
    archive, output = Path(args.archive), Path(args.output).absolute()
    private_parent(output)
    if not re.fullmatch(r'[0-9a-f]{64}', args.sha256) or digest(archive) != args.sha256:
        raise BackupError('Encrypted archive checksum mismatch')
    identity = Path(args.identity)
    if identity.is_symlink() or not identity.is_file() or identity.stat().st_mode & 0o077:
        raise BackupError('Identity must be a private regular file (mode 0600)')
    # Never invoke arbitrary age plugins from an identity file.
    identities = [line.strip() for line in identity.read_text().splitlines()
                  if line.strip() and not line.lstrip().startswith('#')]
    if not identities or any(not re.fullmatch(r'AGE-SECRET-KEY-1[0-9A-Z]{58}', key)
                             for key in identities):
        raise BackupError('Identity must contain native age secret keys')
    output.mkdir(mode=0o700)  # exclusive: cannot overwrite an existing recovery set
    try:
        with tempfile.TemporaryDirectory(prefix='.decrypt-', dir=output) as tmp:
            plain = Path(tmp) / 'payload.tar'
            run(['age', '--decrypt', '--identity', str(identity), '--output', str(plain),
                 str(archive)], stdout=subprocess.DEVNULL)
            # Authentication finishes before any archived file is made available.
            with tarfile.open(plain, 'r:') as tar:
                seen = set()
                for member in tar:
                    name = PurePosixPath(member.name)
                    if (not member.isfile() or name.is_absolute() or '..' in name.parts
                        or member.name != name.as_posix() or member.name in seen
                        or (member.name not in ('manifest.json', 'database.dump')
                            and (not name.parts or name.parts[0] != 'objects'))):
                        raise BackupError('Invalid recovery archive entry')
                    seen.add(member.name)
                    target = output / member.name
                    target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
                    with tar.extractfile(member) as incoming, target.open('xb') as outgoing:
                        shutil.copyfileobj(incoming, outgoing, 1024 * 1024)
                manifest = json.loads((output / 'manifest.json').read_text())
                if not isinstance(manifest, dict) or manifest.get('format') != 'szafa-paired-backup-v1':
                    raise BackupError('Unsupported recovery format')
                expected = manifest['files']
                if (not isinstance(expected, dict) or 'database.dump' not in expected
                    or seen != set(expected) | {'manifest.json'}):
                    raise BackupError('Recovery file inventory mismatch')
                for name, info in expected.items():
                    if (not isinstance(info, dict) or type(info.get('bytes')) is not int
                        or info['bytes'] < 0 or not isinstance(info.get('sha256'), str)
                        or not re.fullmatch(r'[0-9a-f]{64}', info['sha256'])):
                        raise BackupError('Invalid recovery manifest entry')
                    path = output / name
                    if path.stat().st_size != info['bytes'] or digest(path) != info['sha256']:
                        raise BackupError('Recovery file checksum mismatch')
        (output / 'objects').mkdir(mode=0o700, exist_ok=True)
        (output / 'VERIFIED.json').write_text(json.dumps({
            'verified_at': utc(), 'archive_sha256': args.sha256,
            'database_restored': False, 'deletion_replay_completed': False,
            'safe_to_reopen': False}) + '\n')
        return {'verified_files': len(expected), 'safe_to_reopen': False}
    except BaseException:
        # Only the directory created exclusively by this invocation is removed.
        shutil.rmtree(output)
        raise


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    backup = commands.add_parser('capture')
    for flag in ['service', 'objects', 'recipients', 'output']:
        backup.add_argument('--' + flag, required=True)
    backup.add_argument('--writers-stopped', action='store_true')
    restore = commands.add_parser('unpack')
    for flag in ['archive', 'identity', 'sha256', 'output']:
        restore.add_argument('--' + flag, required=True)
    args = parser.parse_args()
    try:
        print(json.dumps(capture(args) if args.command == 'capture' else unpack(args)))
    except (BackupError, OSError, ValueError, KeyError, TypeError, tarfile.TarError) as error:
        # Do not dump paths, private manifest contents, or subprocess diagnostics.
        message = str(error) if isinstance(error, BackupError) else type(error).__name__
        parser.exit(1, 'Recovery operation failed: ' + message + '\n')


if __name__ == '__main__':
    main()
