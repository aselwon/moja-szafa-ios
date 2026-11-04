import importlib.util
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest

SCRIPT = Path(__file__).with_name("bounded-command.py")
spec = importlib.util.spec_from_file_location("bounded_command", SCRIPT)
bounded = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bounded)


class BoundedCommandTests(unittest.TestCase):
    def test_success_and_failure_are_preserved(self):
        for code in (0, 7):
            with self.subTest(code=code):
                self.assertEqual(bounded.run([sys.executable, "-c", f"raise SystemExit({code})"], 5), code)

    def test_hung_command_ignoring_term_is_killed_and_fails(self):
        start = time.monotonic()
        code = bounded.run([sys.executable, "-c",
                            "import signal,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); time.sleep(60)"],
                           .5, grace=.1)
        self.assertEqual(code, 124)
        self.assertLess(time.monotonic() - start, 5)

    def test_descendants_are_killed_even_when_leader_exits_on_term(self):
        with tempfile.TemporaryDirectory() as directory:
            heartbeat = Path(directory) / "heartbeat"
            child = ("import signal,time; from pathlib import Path; "
                     "signal.signal(signal.SIGTERM,signal.SIG_IGN); "
                     f"p=Path({str(heartbeat)!r})\n"
                     "while True:\n p.write_text(str(time.monotonic())); time.sleep(.02)")
            parent = f"import subprocess,sys; subprocess.Popen([sys.executable,'-c',{child!r}]).wait()"
            self.assertEqual(bounded.run([sys.executable, "-c", parent], .5), 124)
            time.sleep(.05)
            last = heartbeat.read_text()
            self.assertTrue(last)
            time.sleep(.1)
            self.assertEqual(heartbeat.read_text(), last)

    def test_invalid_timeout_is_rejected(self):
        result = subprocess.run([sys.executable, str(SCRIPT), "--timeout", "0", "--", sys.executable],
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=5)
        self.assertEqual(result.returncode, 2)

    def test_cancellation_terminates_command_group(self):
        process = subprocess.Popen([sys.executable, str(SCRIPT), "--timeout", "60", "--", sys.executable,
                                    "-c", "import time; print('ready',flush=True); time.sleep(60)"],
                                   stdout=subprocess.PIPE, text=True)
        try:
            self.assertEqual(process.stdout.readline().strip(), "ready")
            process.terminate()
            self.assertEqual(process.wait(timeout=5), 143)
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()
            process.stdout.close()


if __name__ == "__main__":
    unittest.main()
