import fcntl
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest


spec = importlib.util.spec_from_file_location("clone_ios_simulator", Path(__file__).with_name("clone-ios-simulator.py"))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class FakeSimctl:
    def __init__(self, cache):
        self.cache = cache
        self.devices = {}
        self.calls = []
        self.fail_boot = False
        self.fail_clone = False

    def run(self, *args):
        self.calls.append(args)
        # A separate descriptor cannot acquire the active lock, including
        # during bootstatus, shutdown, inventory reads and clone operations.
        locked = False
        for path in self.cache.glob("*.lock"):
            with path.open("a") as competing:
                try:
                    fcntl.flock(competing, fcntl.LOCK_EX | fcntl.LOCK_NB)
                except BlockingIOError:
                    locked = True
        assert locked, "simctl used outside the template lock"
        command = args[0]
        if command == "list":
            result = {}
            for device in self.devices.values():
                result.setdefault(device["runtime"], []).append(device)
            return json.dumps({"devices": result})
        if command == "create":
            identifier = f"template-{len(self.calls)}"
            self.devices[identifier] = {"udid": identifier, "name": args[1],
                                       "deviceTypeIdentifier": args[2], "runtime": args[3],
                                       "state": "Shutdown", "isAvailable": True}
            return identifier
        if command == "bootstatus":
            self.devices[args[1]]["state"] = "Booted"
            if self.fail_boot:
                raise RuntimeError("migration failed")
            return ""
        if command == "shutdown":
            self.devices[args[1]]["state"] = "Shutdown"
            return ""
        if command == "delete":
            del self.devices[args[1]]
            return ""
        if command == "clone":
            assert self.devices[args[1]]["state"] == "Shutdown"
            if self.fail_clone:
                raise RuntimeError("clone failed")
            identifier = f"clone-{len(self.calls)}"
            self.devices[identifier] = dict(self.devices[args[1]], udid=identifier, name=args[2])
            return identifier
        raise AssertionError(args)


class CloneSimulatorTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.cache = Path(self.temporary.name) / "cache"
        self.simctl = FakeSimctl(self.cache)

    def clone(self, **kwargs):
        arguments = dict(cache_dir=self.cache, runtime="ios-26-5", device_type="iphone17",
                         job_name="job", simctl=self.simctl)
        arguments.update(kwargs)
        return module.clone_device(**arguments)

    def record(self):
        return next(self.cache.glob("*.json"))

    def test_initializes_once_then_clones_distinct_isolated_devices(self):
        output = Path(self.temporary.name) / "github-output"
        first = self.clone(output_path=output)
        record = json.loads(self.record().read_text())
        self.assertTrue(record["ready"])
        self.assertEqual(output.read_text(), f"id={first}\n")
        self.assertNotEqual(first, record["id"])
        # A job can boot/change its clone without affecting the template.
        self.simctl.devices[first]["state"] = "Booted"
        second = self.clone(job_name="another-job")
        self.assertNotEqual(first, second)
        self.assertEqual(sum(call[0] == "create" for call in self.simctl.calls), 1)
        self.assertEqual(sum(call[0] == "bootstatus" for call in self.simctl.calls), 1)
        self.assertEqual(self.simctl.devices[record["id"]]["state"], "Shutdown")

    def test_runtime_and_device_type_have_separate_templates(self):
        self.clone()
        self.clone(runtime="ios-27")
        self.clone(device_type="iphone18")
        self.assertEqual(len(list(self.cache.glob("*.json"))), 3)
        self.assertEqual(sum(call[0] == "create" for call in self.simctl.calls), 3)

    def test_incomplete_initialization_is_never_reused(self):
        self.clone()
        path = self.record()
        record = json.loads(path.read_text())
        old_template = record["id"]
        record["ready"] = False
        path.write_text(json.dumps(record))
        self.simctl.devices[old_template]["state"] = "Booted"
        self.clone()
        self.assertNotIn(old_template, self.simctl.devices)
        self.assertNotEqual(json.loads(path.read_text())["id"], old_template)

    def test_mismatched_device_identity_never_clones_or_deletes_user_device(self):
        self.clone()
        record = json.loads(self.record().read_text())
        original = record["id"]
        self.simctl.devices[original]["name"] = "Personal simulator"
        self.simctl.calls.clear()
        self.clone()
        self.assertIn(original, self.simctl.devices)
        self.assertFalse(any(call[0] in ("clone", "delete", "shutdown") and call[1] == original
                             for call in self.simctl.calls))

    def test_missing_template_is_rebuilt(self):
        self.clone()
        record = json.loads(self.record().read_text())
        del self.simctl.devices[record["id"]]
        self.clone()
        self.assertNotEqual(json.loads(self.record().read_text())["id"], record["id"])

    def test_migration_failure_cleans_template_and_releases_lock(self):
        self.simctl.fail_boot = True
        with self.assertRaisesRegex(RuntimeError, "migration failed"):
            self.clone()
        self.assertEqual(self.simctl.devices, {})
        self.assertEqual(list(self.cache.glob("*.json")), [])
        with next(self.cache.glob("*.lock")).open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        self.simctl.fail_boot = False
        self.clone()

    def test_clone_failure_preserves_ready_template(self):
        self.simctl.fail_clone = True
        with self.assertRaisesRegex(RuntimeError, "clone failed"):
            self.clone()
        record = json.loads(self.record().read_text())
        self.assertTrue(record["ready"])
        self.assertEqual(self.simctl.devices[record["id"]]["state"], "Shutdown")
        self.simctl.fail_clone = False
        self.clone()
        self.assertEqual(sum(call[0] == "bootstatus" for call in self.simctl.calls), 1)

    def test_output_failure_deletes_clone_but_keeps_template(self):
        with self.assertRaises(IsADirectoryError):
            self.clone(output_path=self.cache)
        self.assertEqual(len(self.simctl.devices), 1)
        self.assertTrue(json.loads(self.record().read_text())["ready"])


if __name__ == "__main__":
    unittest.main()
