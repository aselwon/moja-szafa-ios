import argparse
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('paired', Path(__file__).with_name('paired-backup.py'))
paired = importlib.util.module_from_spec(spec)
spec.loader.exec_module(paired)


class PairedRecoveryTests(unittest.TestCase):
    def setUp(self):
        self.old_mask = os.umask(0o077)
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.key = self.root / 'identity'
        subprocess.run(['age-keygen', '-o', str(self.key)], check=True, stderr=subprocess.DEVNULL)
        self.recipients = self.root / 'recipients'
        self.recipients.write_bytes(subprocess.check_output(['age-keygen', '-y', str(self.key)]))
        self.files = {'database.dump': b'PGDMP synthetic envelope test',
                      'objects/opaque/original.jpg': b'private original bytes',
                      'objects/opaque/cleaned.png': b'private cleaned bytes'}

    def tearDown(self):
        self.tmp.cleanup()
        os.umask(self.old_mask)

    def encrypted(self, extra=None, bad_hash=False):
        manifest = {'format': 'szafa-paired-backup-v1', 'files': {
            name: {'bytes':len(data), 'sha256':hashlib.sha256(data).hexdigest()}
            for name, data in self.files.items()}}
        if bad_hash:
            manifest['files']['database.dump']['sha256'] = '0' * 64
        plain = self.root / 'payload.tar'
        with tarfile.open(plain, 'w') as archive:
            for name, data in {**self.files, 'manifest.json':json.dumps(manifest).encode()}.items():
                info = tarfile.TarInfo(name)
                info.size = len(data)
                archive.addfile(info, io.BytesIO(data))
            if extra:
                archive.addfile(extra, io.BytesIO(b'x' * extra.size))
        encrypted = self.root / 'payload.age'
        subprocess.run(['age','-R',str(self.recipients),'-o',str(encrypted),str(plain)], check=True)
        return argparse.Namespace(archive=str(encrypted), identity=str(self.key),
                                  sha256=paired.digest(encrypted), output=str(self.root/'restored'))

    def test_verified_bytes_are_private_and_do_not_authorize_reopening(self):
        args = self.encrypted()
        self.assertEqual(paired.unpack(args), {'verified_files':3, 'safe_to_reopen':False})
        output = Path(args.output)
        for name, expected in self.files.items():
            self.assertEqual((output/name).read_bytes(), expected)
            self.assertEqual((output/name).stat().st_mode & 0o077, 0)
        self.assertFalse(json.loads((output/'VERIFIED.json').read_text())['database_restored'])

    def test_ciphertext_tampering_fails_even_with_recomputed_outer_hash(self):
        args = self.encrypted()
        archive = Path(args.archive)
        data = bytearray(archive.read_bytes())
        data[-20] ^= 1
        archive.write_bytes(data)
        args.sha256 = paired.digest(archive)
        with self.assertRaises(paired.BackupError):
            paired.unpack(args)
        self.assertFalse(Path(args.output).exists())

    def test_wrong_identity_leaves_no_plaintext_directory(self):
        args = self.encrypted()
        other = self.root / 'other-identity'
        subprocess.run(['age-keygen','-o',str(other)],check=True,stderr=subprocess.DEVNULL)
        args.identity = str(other)
        with self.assertRaises(paired.BackupError):
            paired.unpack(args)
        self.assertFalse(Path(args.output).exists())

    def test_untrusted_archive_paths_links_duplicates_and_manifest_mismatch_fail(self):
        for name, kind in [('../outside',tarfile.REGTYPE),('/absolute',tarfile.REGTYPE),
                           ('objects/link',tarfile.SYMTYPE),('database.dump',tarfile.REGTYPE),
                           ('objects/hardlink',tarfile.LNKTYPE)]:
            with self.subTest(name=name):
                entry = tarfile.TarInfo(name)
                entry.type, entry.linkname = kind, '../outside'
                args = self.encrypted(extra=entry)
                with self.assertRaises(paired.BackupError):
                    paired.unpack(args)
                self.assertFalse(Path(args.output).exists())
        args = self.encrypted(bad_hash=True)
        with self.assertRaises(paired.BackupError):
            paired.unpack(args)
        self.assertFalse(Path(args.output).exists())
        self.assertFalse((self.root/'outside').exists())

    def test_existing_destination_is_never_removed_or_overwritten(self):
        args = self.encrypted()
        destination = Path(args.output)
        destination.mkdir()
        (destination/'sentinel').write_text('keep')
        with self.assertRaises(FileExistsError):
            paired.unpack(args)
        self.assertEqual((destination/'sentinel').read_text(), 'keep')

    def test_capture_requires_fencing_and_rejects_links_and_source_changes(self):
        photos = self.root / 'photos'
        photos.mkdir()
        photo = photos / 'original.jpg'
        photo.write_bytes(b'original')
        args = argparse.Namespace(service='fixture', objects=str(photos),
                                  recipients=str(self.recipients), output=str(self.root/'backup.age'),
                                  writers_stopped=False)
        with self.assertRaises(paired.BackupError):
            paired.capture(args)
        args.writers_stopped = True
        (photos/'linked.jpg').symlink_to(photo)
        with self.assertRaises(paired.BackupError):
            paired.capture(args)
        (photos/'linked.jpg').unlink()
        def change_source(command, **kwargs):
            if command[0] == 'psql':
                return argparse.Namespace(stdout=b'[]')
            if command[0] == 'pg_dump':
                kwargs['stdout'].write(b'fake dump for mutation test only')
            if command[0] == 'pg_restore':
                photo.write_bytes(b'changed by a writer that was not fenced')
        with patch.object(paired, 'run', side_effect=change_source):
            with self.assertRaises(paired.BackupError):
                paired.capture(args)
        self.assertFalse(Path(args.output).exists())
        self.assertFalse(list(self.root.glob('.paired-capture-*')))


if __name__ == '__main__':
    unittest.main()
