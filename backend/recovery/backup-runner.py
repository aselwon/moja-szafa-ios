#!/usr/bin/env python3
"""Coordinate a bounded, local-host paired capture. Does not enable a schedule."""
import argparse
import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import resource
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time
import urllib.request
import uuid
from datetime import datetime, timezone

SPEC = importlib.util.spec_from_file_location('paired', Path(__file__).with_name('paired-backup.py'))
paired = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(paired)
PATH = '/usr/local/bin:/usr/bin:/bin'


class RunnerError(Exception):
    pass


def utc():
    return datetime.now(timezone.utc).isoformat()


def private_file(path):
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_uid != os.geteuid() or info.st_mode & 0o077:
        raise RunnerError('private_file_required')


def load_config(path):
    private_file(path)
    config = json.loads(path.read_text())
    keys = {'service', 'service_file', 'objects', 'recipients', 'output', 'writer_units',
            'health_urls', 'lease_seconds', 'capture_seconds', 'max_file_bytes', 'reserve_bytes'}
    if not isinstance(config, dict) or set(config) != keys:
        raise RunnerError('invalid_config')
    if not isinstance(config['service'], str) or not re.fullmatch(r'[A-Za-z0-9_-]{1,64}', config['service']):
        raise RunnerError('invalid_service')
    units = config['writer_units']
    if not isinstance(units, list) or not 1 <= len(units) <= 8 or any(
        not isinstance(unit, str) or not re.fullmatch(r'moja-szafa-[A-Za-z0-9_.-]+\.service', unit) for unit in units
    ) or len(set(units)) != len(units):
        raise RunnerError('invalid_writer_units')
    if not isinstance(config['health_urls'], list) or any(
        not isinstance(url, str) or not re.fullmatch(r'http://127\.0\.0\.1:[0-9]{1,5}/health', url)
        for url in config['health_urls']
    ):
        raise RunnerError('invalid_health_urls')
    for key, low, high in [('lease_seconds', 90, 900), ('capture_seconds', 10, 840),
                           ('max_file_bytes', 1024 * 1024, 4 * 1024**3),
                           ('reserve_bytes', 256 * 1024**2, 100 * 1024**3)]:
        if type(config[key]) is not int or not low <= config[key] <= high:
            raise RunnerError('invalid_limits')
    if config['capture_seconds'] + 45 >= config['lease_seconds']:
        raise RunnerError('insufficient_resume_margin')
    for key in ('service_file', 'objects', 'recipients', 'output'):
        value = config[key]
        if not isinstance(value, str) or not Path(value).is_absolute() or Path(value).is_symlink():
            raise RunnerError('invalid_path')
        config[key] = Path(value).resolve(strict=True)
    private_file(config['service_file'])
    output = config['output']
    info = output.stat()
    if not output.is_dir() or info.st_uid != os.geteuid() or info.st_mode & 0o077:
        raise RunnerError('private_output_required')
    objects = config['objects']
    if not objects.is_dir() or output == objects or objects in output.parents or output in objects.parents:
        raise RunnerError('overlapping_paths')
    recipients = config['recipients']
    info = recipients.stat()
    if not recipients.is_file() or info.st_uid != os.geteuid() or info.st_mode & 0o022:
        raise RunnerError('unsafe_recipients_file')
    public = [line.strip() for line in recipients.read_text().splitlines() if line.strip() and not line.lstrip().startswith('#')]
    if not public or any(not re.fullmatch(r'age1[0-9a-z]{58}', key) for key in public):
        raise RunnerError('public_recipients_required')
    return config


def execute(command, timeout=20, env=None, max_file_bytes=None):
    def limit():
        resource.setrlimit(resource.RLIMIT_FSIZE, (max_file_bytes, max_file_bytes))
    process = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                               stderr=subprocess.DEVNULL, env=env, start_new_session=True,
                               preexec_fn=limit if max_file_bytes else None)
    try:
        output, _ = process.communicate(timeout=timeout)
    except BaseException:
        # Kill the capture's entire tree, including pg_dump/age, before removing
        # private temporary files or releasing the writer fence.
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait()
        raise
    finally:
        if process.stdout is not None:
            process.stdout.close()
    if process.returncode:
        raise RunnerError('command_failed')
    return output


class Systemd:
    def state(self, unit):
        return execute(['/usr/bin/systemctl', 'show', unit, '-p', 'ActiveState', '--value']).decode().strip()

    def watchdog(self, name, seconds, units):
        execute(['/usr/bin/systemd-run', '--quiet', '--collect', '--unit=' + name,
                 '--on-active=' + str(seconds) + 's', '--timer-property=AccuracySec=1s',
                 '/usr/bin/systemctl', 'start'] + units)

    def stop(self, units):
        execute(['/usr/bin/systemctl', 'stop'] + units)

    def start(self, units):
        execute(['/usr/bin/systemctl', 'start'] + units)

    def disarm(self, name):
        execute(['/usr/bin/systemctl', 'stop', name + '.timer'])

    def health(self, urls):
        # Never follow redirects, proxies or remote destinations from this probe.
        class NoRedirect(urllib.request.HTTPRedirectHandler):
            def redirect_request(self, *args, **kwargs):
                return None
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
        for url in urls:
            healthy = False
            for _ in range(5):
                try:
                    with opener.open(url, timeout=1) as response:
                        healthy = response.status == 200
                except (OSError, urllib.error.URLError):
                    pass
                if healthy:
                    break
                time.sleep(1)
            if not healthy:
                raise RunnerError('resume_health_failed')


def capture(config, stage, timeout):
    env = {'PATH': PATH, 'LANG': 'C.UTF-8', 'PGSERVICEFILE': str(config['service_file']),
           'PGCONNECT_TIMEOUT': '15', 'PGOPTIONS': '-c default_transaction_read_only=on'}
    raw = execute([sys.executable, str(Path(__file__).with_name('paired-backup.py')),
                   'capture', '--service', config['service'], '--objects', str(config['objects']),
                   '--recipients', str(config['recipients']), '--output', str(stage / 'backup.age'),
                   '--writers-stopped'], timeout=timeout, env=env, max_file_bytes=config['max_file_bytes'])
    return json.loads(raw)


def atomic_json(path, value):
    fd, temp = tempfile.mkstemp(prefix='.status-', dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as stream:
            json.dump(value, stream, sort_keys=True)
            stream.write('\n')
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temp, path)
        directory = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        Path(temp).unlink(missing_ok=True)


def coordinate(config, controller=None, capture_fn=capture, clock=time.monotonic):
    controller = controller or Systemd()
    output = config['output']
    lock = os.open(output / '.runner.lock', os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        info = os.fstat(lock)
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_uid != os.geteuid() or info.st_mode & 0o077:
            raise RunnerError('unsafe_lock')
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise RunnerError('backup_already_running') from None
        return locked_capture(config, controller, capture_fn, clock)
    finally:
        os.close(lock)


def locked_capture(config, controller, capture_fn, clock):
    output = config['output']
    status_path = output / 'status.json'
    last_success = None
    if status_path.exists():
        private_file(status_path)
        last_success = json.loads(status_path.read_text()).get('last_success')
    status = {'format': 'szafa-backup-runner-v1', 'started_at': utc(), 'state': 'running',
              'last_success': last_success, 'off_host_verified': False}
    atomic_json(status_path, status)
    try:
        sizes = paired.inventory(config['objects']).values()
        photo_bytes = sum(entry[3] for entry in sizes if stat.S_ISREG(entry[2]))
        # Conservative space budget for payload, tar and ciphertext. Every child
        # file is also bounded by RLIMIT_FSIZE. Existing backups are never erased.
        needed = 3 * (photo_bytes + config['max_file_bytes']) + config['reserve_bytes']
        if shutil.disk_usage(output).free < needed:
            raise RunnerError('insufficient_free_space')
        states = {unit: controller.state(unit) for unit in config['writer_units']}
        if any(state not in ('active', 'inactive') for state in states.values()):
            raise RunnerError('writer_state_not_stable')
        active = [unit for unit, state in states.items() if state == 'active']
        name = 'moja-szafa-backup-resume-' + uuid.uuid4().hex
        deadline = clock() + config['lease_seconds']
        armed = False
        with tempfile.TemporaryDirectory(prefix='.runner-', dir=output) as temporary:
            stage = Path(temporary)
            try:
                if active:
                    # No writer is stopped unless watchdog creation succeeded.
                    controller.watchdog(name, config['lease_seconds'], active)
                    armed = True
                    controller.stop(active)
                if any(controller.state(unit) != 'inactive' for unit in states):
                    raise RunnerError('writers_not_fenced')
                remaining = min(config['capture_seconds'], deadline - clock() - 30)
                if remaining <= 0:
                    raise RunnerError('freeze_lease_expired')
                result = capture_fn(config, stage, remaining)
                if clock() >= deadline - 15 or any(controller.state(unit) != 'inactive' for unit in states):
                    raise RunnerError('freeze_lease_expired')
            finally:
                if armed:
                    # Leave the independent watchdog armed if any explicit
                    # resume/health check fails; never disable the safety net.
                    controller.start(active)
                    if any(controller.state(unit) != 'active' for unit in active):
                        raise RunnerError('writer_resume_failed')
                    controller.health(config['health_urls'])
                    controller.disarm(name)
            archive = stage / 'backup.age'
            if not isinstance(result, dict) or set(result) != {'sha256', 'recovery_point_at', 'object_files', 'encrypted_bytes'}:
                raise RunnerError('invalid_capture_receipt')
            if not isinstance(result['sha256'], str) or not re.fullmatch(r'[0-9a-f]{64}', result['sha256']):
                raise RunnerError('invalid_capture_receipt')
            if type(result['encrypted_bytes']) is not int or type(result['object_files']) is not int or result['object_files'] < 0:
                raise RunnerError('invalid_capture_receipt')
            private_file(archive)
            if archive.stat().st_size != result['encrypted_bytes'] or paired.digest(archive) != result['sha256']:
                raise RunnerError('ciphertext_mismatch')
            point = datetime.fromisoformat(result['recovery_point_at'])
            if point.tzinfo is None or point > datetime.now(timezone.utc):
                raise RunnerError('invalid_recovery_point')
            filename = 'paired-' + datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ-') + uuid.uuid4().hex + '.age'
            os.link(archive, output / filename)
            receipt = dict(result, archive=filename, verified_at=utc(), off_host_verified=False)
            atomic_json(output / (filename + '.json'), receipt)
            status.update(state='local_verified', last_success=receipt)
    except BaseException as error:
        status.update(state='failed', failure_code=str(error) if isinstance(error, RunnerError) else type(error).__name__)
        raise
    finally:
        status['finished_at'] = utc()
        atomic_json(status_path, status)
    return status


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', type=Path, required=True)
    args = parser.parse_args()
    os.umask(0o077)
    if os.geteuid() != 0:
        raise RunnerError('root_required_for_writer_coordination')
    config = load_config(args.config)
    for tool in ('psql', 'pg_dump', 'pg_restore', 'age'):
        if shutil.which(tool, path=PATH) is None:
            raise RunnerError('missing_capture_dependency')
    coordinate(config)
    print('Local encrypted backup verified; off-host replication is still required.')


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        print('Backup runner failed: ' + (str(error) if isinstance(error, RunnerError) else type(error).__name__), file=sys.stderr)
        raise SystemExit(1)
