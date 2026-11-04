#!/usr/bin/env python3
"""Clone an isolated CI device from an initialized, otherwise blank template."""

import argparse
import fcntl
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import uuid


class Simctl:
    def run(self, *args):
        result = subprocess.run(["xcrun", "simctl", *args], check=True,
                                stdout=subprocess.PIPE, text=True)
        return result.stdout.strip()


def save_record(path, record):
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(record))
    temporary.replace(path)


def owned_device(simctl, record, runtime, device_type):
    """Never delete or clone a device solely because a cached UUID names it."""
    devices = json.loads(simctl.run("list", "devices", "--json"))["devices"]
    for device in devices.get(runtime, []):
        if (device.get("udid") == record.get("id")
                and device.get("name") == record.get("name")
                and device.get("deviceTypeIdentifier") == device_type
                and device.get("isAvailable", False)):
            return device
    return None


def clone_device(cache_dir, runtime, device_type, job_name, simctl, output_path=None):
    cache_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
    key = hashlib.sha256(f"v1\n{runtime}\n{device_type}".encode()).hexdigest()[:24]
    record_path = cache_dir / f"{key}.json"
    # flock is released by the OS on crashes/cancellation. The same lock covers
    # first boot AND clone, so no job can copy a booting/migrating template.
    with (cache_dir / f"{key}.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        try:
            record = json.loads(record_path.read_text())
        except (FileNotFoundError, ValueError):
            record = {}
        if not isinstance(record, dict):
            record = {}
        prefix = f"MojaSzafa-Blank-v1-{key}-"
        valid_record = (record.get("runtime") == runtime
                        and record.get("device_type") == device_type
                        and isinstance(record.get("name"), str)
                        and record["name"].startswith(prefix))
        device = owned_device(simctl, record, runtime, device_type) if valid_record else None
        ready = device and record.get("ready") is True and device.get("state") == "Shutdown"
        if not ready:
            if device:
                if device.get("state") != "Shutdown":
                    simctl.run("shutdown", device["udid"])
                simctl.run("delete", device["udid"])
            record_path.unlink(missing_ok=True)
            name = prefix + str(uuid.uuid4())
            template = simctl.run("create", name, device_type, runtime)
            record = {"id": template, "name": name, "runtime": runtime,
                      "device_type": device_type, "ready": False}
            try:
                save_record(record_path, record)
                print(f"Initializing fresh blank template {template}", file=sys.stderr, flush=True)
                # This device is freshly created: no app, account or test data
                # is installed. It is never returned to a test job or booted
                # again after the readiness marker is committed.
                status = simctl.run("bootstatus", template, "-b")
                if status:
                    print(status, file=sys.stderr)
                simctl.run("shutdown", template)
                initialized = owned_device(simctl, record, runtime, device_type)
                if not initialized or initialized.get("state") != "Shutdown":
                    raise RuntimeError("Template did not reach Shutdown after initialization")
                record["ready"] = True
                save_record(record_path, record)
            except BaseException:
                # Keep the incomplete record if cleanup fails; the next lock
                # holder will verify ownership and retry cleanup, never reuse it.
                try:
                    simctl.run("shutdown", template)
                except Exception:
                    pass
                try:
                    simctl.run("delete", template)
                    record_path.unlink(missing_ok=True)
                except Exception:
                    pass
                raise
        print(f"Cloning shutdown blank template {record['id']}", file=sys.stderr, flush=True)
        clone = simctl.run("clone", record["id"], job_name)
        try:
            if output_path:
                # Persist job ownership before any boot attempt, including if
                # the surrounding shell is cancelled immediately after return.
                with Path(output_path).open("a") as output:
                    output.write(f"id={clone}\n")
            return clone
        except BaseException:
            simctl.run("delete", clone)
            raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runtime", required=True)
    parser.add_argument("--device-type", required=True)
    parser.add_argument("--name", required=True)
    parser.add_argument("--cache-dir", type=Path, default=Path.home() / "Library/Caches/MojaSzafa/blank-simulators")
    parser.add_argument("--github-output")
    args = parser.parse_args()
    print(clone_device(args.cache_dir, args.runtime, args.device_type, args.name,
                       Simctl(), args.github_output))


if __name__ == "__main__":
    main()
