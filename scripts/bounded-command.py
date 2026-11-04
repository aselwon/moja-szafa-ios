#!/usr/bin/env python3
"""Bound a CI command, terminating only its dedicated process group on timeout."""
import argparse
import os
import signal
import subprocess
import sys


def signal_group(pid, sig):
    try:
        os.killpg(pid, sig)
    except ProcessLookupError:
        pass


def run(command, timeout, grace=5):
    process = subprocess.Popen(command, start_new_session=True)
    try:
        try:
            return process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            print("CI command timed out; terminating its process group", file=sys.stderr, flush=True)
            return 124
    finally:
        if process.poll() is None:
            signal_group(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=grace)
            except subprocess.TimeoutExpired:
                pass
            # A leader may exit before its descendants. Reap the entire group.
            signal_group(process.pid, signal.SIGKILL)
            process.wait()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--timeout", type=float, required=True)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if args.timeout <= 0 or not command:
        parser.error("a positive timeout and command are required")
    # A cancelled CI step must also clean up this command's children.
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
    return run(command, args.timeout)


if __name__ == "__main__":
    sys.exit(main())
