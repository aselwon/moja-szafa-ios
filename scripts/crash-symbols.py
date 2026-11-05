#!/usr/bin/env python3
"""Private immutable dSYM archive and UUID-checked MetricKit frame symbolication.
No network, credentials, shell interpolation, or raw crash-payload collection.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import uuid

ARCHES = {"arm64", "arm64e", "x86_64"}

def command(*args):
    result = subprocess.run(["xcrun", *args], capture_output=True, text=True, timeout=30, check=False)
    if result.returncode:
        raise ValueError("symbol_tool_failed")
    return result.stdout

def identities(path):
    return {(str(uuid.UUID(match[0])).upper(), match[1]) for match in
            re.findall(r"UUID: ([0-9A-Fa-f-]{36}) \(([^)]+)\)", command("dwarfdump", "--uuid", str(path)))}

def digest(path):
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()

def archive_symbols(source, archive, commit=None):
    source, archive = source.resolve(), archive.resolve()
    if commit is not None and not re.fullmatch(r"[0-9a-f]{40}", commit):
        raise ValueError("invalid_commit")
    bundles = [source] if source.name.endswith(".dSYM") else sorted(source.rglob("*.dSYM"))
    imported = []
    for bundle in bundles:
        if bundle.is_symlink() or not bundle.resolve().is_relative_to(source):
            raise ValueError("unsafe_symbol_path")
        for binary in sorted((bundle / "Contents/Resources/DWARF").glob("*")):
            if binary.is_symlink() or not binary.is_file() or not binary.resolve().is_relative_to(source):
                raise ValueError("unsafe_symbol_path")
            checksum = digest(binary)
            found = identities(binary)
            if not found:
                raise ValueError("missing_symbol_uuid")
            for identifier, arch in sorted(found):
                if arch not in ARCHES:
                    continue
                folder = archive / identifier / arch
                folder.mkdir(parents=True, exist_ok=True, mode=0o700)
                destination = folder / "symbols"
                with tempfile.NamedTemporaryFile(dir=folder, delete=False) as stream:
                    temporary = Path(stream.name)
                    try:
                        with binary.open("rb") as original:
                            shutil.copyfileobj(original, stream)
                        stream.flush(); os.fsync(stream.fileno())
                        try:
                            os.link(temporary, destination)  # Atomic, never overwrites another UUID's symbols.
                        except FileExistsError:
                            if destination.is_symlink() or digest(destination) != checksum:
                                raise ValueError("immutable_symbol_conflict")
                    finally:
                        temporary.unlink(missing_ok=True)
                metadata = {"uuid": identifier, "architecture": arch, "sha256": checksum,
                            "binary_name": binary.name, "commit": commit}
                manifest = folder / "manifest.json"
                try:
                    with manifest.open("x") as stream:
                        json.dump(metadata, stream, sort_keys=True)
                    manifest.chmod(0o600)
                except FileExistsError:
                    old = json.loads(manifest.read_text())
                    if any(old.get(key) != metadata[key] for key in ("uuid", "architecture", "sha256")):
                        raise ValueError("immutable_manifest_conflict")
                imported.append(metadata)
    if not imported:
        raise ValueError("no_supported_symbols")
    return imported

def text_address(binary, arch):
    output = command("otool", "-l", "-arch", arch, str(binary))
    match = re.search(r"segname __TEXT\s+vmaddr (0x[0-9a-fA-F]+)", output)
    if not match:
        raise ValueError("missing_text_segment")
    return int(match.group(1), 16)

def symbolicate(report, archive):
    if not isinstance(report, dict) or set(report) - {"id", "kind", "build", "architecture", "frames"}:
        raise ValueError("invalid_crash_report")
    arch, frames = report.get("architecture"), report.get("frames")
    if arch not in ARCHES or not isinstance(frames, list) or len(frames) > 64:
        raise ValueError("invalid_crash_report")
    archive = archive.resolve()
    results, groups = [], {}
    for frame in frames:
        if not isinstance(frame, dict) or set(frame) != {"binaryUUID", "offset"} or type(frame["offset"]) is not int or not 0 <= frame["offset"] <= 9007199254740991:
            raise ValueError("invalid_crash_frame")
        identifier = str(uuid.UUID(frame["binaryUUID"])).upper()
        row = {"binaryUUID": identifier, "offset": frame["offset"], "status": "symbols_missing", "symbol": None}
        results.append(row); groups.setdefault(identifier, []).append(row)
    for identifier, rows in groups.items():
        binary = archive / identifier / arch / "symbols"
        if not binary.is_file():
            continue
        if binary.is_symlink() or not binary.resolve().is_relative_to(archive):
            raise ValueError("unsafe_symbol_path")
        try:
            manifest = json.loads(binary.with_name("manifest.json").read_text())
            if manifest.get("sha256") != digest(binary) or (identifier, arch) not in identities(binary):
                for row in rows: row["status"] = "uuid_or_checksum_mismatch"
                continue
            base = text_address(binary, arch)
            lines = command("atos", "-arch", arch, "-o", str(binary), "-l", hex(base),
                            *[hex(base + row["offset"]) for row in rows]).splitlines()
            if len(lines) != len(rows):
                raise ValueError("unexpected_symbol_output")
            for row, line in zip(rows, lines):
                if line and not re.fullmatch(r"0x[0-9a-fA-F]+", line.strip()):
                    row["status"] = "symbolicated"; row["symbol"] = line
                else:
                    row["status"] = "unresolved"
        except (OSError, ValueError, subprocess.TimeoutExpired):
            for row in rows: row["status"] = "symbolication_failed"
    return {"build": report.get("build"), "architecture": arch, "frames": results}

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="action", required=True)
    archive = sub.add_parser("archive")
    archive.add_argument("--source", type=Path, required=True)
    archive.add_argument("--archive", type=Path, required=True)
    archive.add_argument("--commit")
    decode = sub.add_parser("symbolicate")
    decode.add_argument("--report", type=Path, required=True)
    decode.add_argument("--archive", type=Path, required=True)
    args = parser.parse_args()
    try:
        if args.action == "archive":
            value = archive_symbols(args.source, args.archive, args.commit)
        else:
            with args.report.open("rb") as stream: raw = stream.read(65537)
            if len(raw) > 65536: raise ValueError("report_too_large")
            value = symbolicate(json.loads(raw), args.archive)
        print(json.dumps(value, indent=2))
    except (OSError, ValueError, subprocess.TimeoutExpired):
        print("crash_symbol_operation_failed", file=sys.stderr)
        return 1
    return 0

if __name__ == "__main__":
    sys.exit(main())
