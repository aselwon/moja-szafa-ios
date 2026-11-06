import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('runner', Path(__file__).with_name('backup-runner.py'))
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class Controller:
    def __init__(self):
        self.states = {'moja-szafa-gateway-staging.service': 'active',
                       'moja-szafa-ai-staging.service': 'inactive'}
        self.events = []
        self.fail_watchdog = False
        self.fail_health = False

    def state(self, unit):
        return self.states[unit]

    def watchdog(self, name, seconds, units):
        self.events.append(('watchdog', list(units)))
        if self.fail_watchdog:
            raise RuntimeError('watchdog unavailable')

    def stop(self, units):
        self.events.append(('stop', list(units)))
        for unit in units:
            self.states[unit] = 'inactive'

    def start(self, units):
        self.events.append(('start', list(units)))
        for unit in units:
            self.states[unit] = 'active'

    def health(self, urls):
        self.events.append(('health', list(urls)))
        if self.fail_health:
            raise runner.RunnerError('resume_health_failed')

    def disarm(self, name):
        self.events.append(('disarm', name))


class RunnerTests(unittest.TestCase):
    def setUp(self):
        self.mask = os.umask(0o077)
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        for directory in ['objects', 'backups']:
            (self.root/directory).mkdir()
        (self.root/'objects'/'synthetic.jpg').write_bytes(b'synthetic photo')
        self.config = dict(objects=self.root/'objects', output=self.root/'backups',
                           max_file_bytes=1024, reserve_bytes=1024, lease_seconds=180,
                           capture_seconds=90,
                           writer_units=['moja-szafa-gateway-staging.service', 'moja-szafa-ai-staging.service'],
                           health_urls=['http://127.0.0.1:18083/health'])
        self.controller = Controller()

    def tearDown(self):
        self.temp.cleanup()
        os.umask(self.mask)

    def capture(self, config, stage, timeout):
        self.assertTrue(all(value == 'inactive' for value in self.controller.states.values()))
        self.assertGreater(timeout, 0)
        data = b'synthetic encrypted archive'
        (stage/'backup.age').write_bytes(data)
        return dict(sha256=hashlib.sha256(data).hexdigest(), recovery_point_at=runner.utc(),
                    object_files=1, encrypted_bytes=len(data))

    def run_capture(self, capture=None, clock=None):
        args = dict(controller=self.controller, capture_fn=capture or self.capture)
        if clock is not None:
            args['clock'] = clock
        return runner.coordinate(self.config, **args)

    def status(self):
        return json.loads((self.config['output']/'status.json').read_text())

    def test_success_resumes_only_previously_active_writers_and_publishes_verified_archive(self):
        result = self.run_capture()
        self.assertEqual(result['state'], 'local_verified')
        self.assertFalse(result['off_host_verified'])
        receipt = result['last_success']
        self.assertEqual(runner.paired.digest(self.config['output']/receipt['archive']), receipt['sha256'])
        self.assertEqual(self.controller.states['moja-szafa-ai-staging.service'], 'inactive')
        self.assertEqual([event[0] for event in self.controller.events], ['watchdog', 'stop', 'start', 'health', 'disarm'])
        self.assertEqual(len(self.controller.events[1][1]), 1)

    def test_watchdog_failure_never_stops_writers(self):
        self.controller.fail_watchdog = True
        with self.assertRaises(RuntimeError):
            self.run_capture()
        self.assertEqual([event[0] for event in self.controller.events], ['watchdog'])
        self.assertEqual(self.status()['state'], 'failed')

    def test_capture_timeout_resumes_writers_and_preserves_previous_success(self):
        original = self.run_capture()['last_success']
        def failed(*args):
            raise subprocess.TimeoutExpired('synthetic capture', 90)
        with self.assertRaises(subprocess.TimeoutExpired):
            self.run_capture(failed)
        self.assertEqual(self.status()['last_success'], original)
        self.assertEqual(self.controller.states['moja-szafa-gateway-staging.service'], 'active')
        self.assertEqual(len(list(self.config['output'].glob('paired-*.age'))), 1)

    def test_resume_health_failure_leaves_watchdog_armed_and_does_not_publish(self):
        self.controller.fail_health = True
        with self.assertRaisesRegex(runner.RunnerError, 'resume_health_failed'):
            self.run_capture()
        self.assertNotIn('disarm', [event[0] for event in self.controller.events])
        self.assertEqual(list(self.config['output'].glob('paired-*.age')), [])

    def test_writer_restarting_during_capture_invalidates_pair(self):
        def restarted(*args):
            result = self.capture(*args)
            self.controller.states['moja-szafa-gateway-staging.service'] = 'active'
            return result
        with self.assertRaisesRegex(runner.RunnerError, 'freeze_lease_expired'):
            self.run_capture(restarted)
        self.assertEqual(list(self.config['output'].glob('paired-*.age')), [])

    def test_tampered_receipt_is_not_published(self):
        def tampered(*args):
            result = self.capture(*args)
            result['sha256'] = '0' * 64
            return result
        with self.assertRaisesRegex(runner.RunnerError, 'ciphertext_mismatch'):
            self.run_capture(tampered)
        self.assertEqual(list(self.config['output'].glob('paired-*.age')), [])

    def test_low_disk_space_does_not_stop_writers(self):
        with patch.object(runner.shutil, 'disk_usage') as space:
            space.return_value.free = 0
            with self.assertRaisesRegex(runner.RunnerError, 'insufficient_free_space'):
                self.run_capture()
        self.assertEqual(self.controller.events, [])

    def test_concurrent_capture_is_rejected_without_touching_outer_operation(self):
        def nested(*args):
            with self.assertRaisesRegex(runner.RunnerError, 'backup_already_running'):
                self.run_capture()
            return self.capture(*args)
        self.assertEqual(self.run_capture(nested)['state'], 'local_verified')

    def test_timeout_terminates_capture_descendants(self):
        marker = self.root/'orphan-wrote-data'
        child = "import time,pathlib;time.sleep(0.5);pathlib.Path(" + repr(str(marker)) + ").write_text('unexpected')"
        parent = "import subprocess,sys,time;subprocess.Popen([sys.executable,'-c'," + repr(child) + "]);time.sleep(5)"
        with self.assertRaises(subprocess.TimeoutExpired):
            runner.execute([sys.executable, '-c', parent], timeout=0.15)
        time.sleep(0.7)
        self.assertFalse(marker.exists())


if __name__ == '__main__':
    unittest.main()
