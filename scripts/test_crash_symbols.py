import importlib.util
import json
from pathlib import Path
import re
import subprocess
import tempfile
import unittest
import uuid

spec = importlib.util.spec_from_file_location("crash_symbols", Path(__file__).with_name("crash-symbols.py"))
symbols = importlib.util.module_from_spec(spec); spec.loader.exec_module(symbols)

class SymbolTests(unittest.TestCase):
    def test_real_compiled_dsym_uuid_archive_and_symbolication(self):
        with tempfile.TemporaryDirectory(prefix="szafa-symbols-") as temporary:
            root = Path(temporary)
            source = root / "probe.c"
            source.write_text("__attribute__((noinline)) int telemetry_symbol_probe(int value) { return value + 7; }\nint main(void) { return telemetry_symbol_probe(2); }\n")
            binary = root / "probe"
            symbols.command("clang", "-g", "-O0", "-o", str(binary), str(source))
            bundle = root / "probe.dSYM"
            symbols.command("dsymutil", "-o", str(bundle), str(binary))
            archive = root / "private-symbols"
            metadata = symbols.archive_symbols(bundle, archive, "a" * 40)
            identifier, arch = metadata[0]["uuid"], metadata[0]["architecture"]
            match = re.search(r"^([0-9a-fA-F]+)\s+\w\s+_telemetry_symbol_probe$", symbols.command("nm", "-n", str(binary)), re.M)
            self.assertIsNotNone(match)
            offset = int(match.group(1), 16) - symbols.text_address(binary, arch)
            report = {"build": "1", "architecture": arch, "frames": [{"binaryUUID": identifier, "offset": offset}]}
            result = symbols.symbolicate(report, archive)
            self.assertEqual(result["frames"][0]["status"], "symbolicated")
            self.assertIn("telemetry_symbol_probe", result["frames"][0]["symbol"])
            self.assertEqual(symbols.archive_symbols(bundle, archive, "a" * 40), metadata)
            report["frames"][0]["binaryUUID"] = str(uuid.uuid4())
            self.assertEqual(symbols.symbolicate(report, archive)["frames"][0]["status"], "symbols_missing")
            report["frames"][0]["binaryUUID"] = identifier
            (archive / identifier / arch / "symbols").write_bytes(b"corrupted")
            self.assertEqual(symbols.symbolicate(report, archive)["frames"][0]["status"], "uuid_or_checksum_mismatch")

    def test_report_rejects_raw_content_and_non_integer_offsets(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for report in [{"architecture": "arm64", "frames": [], "email": "private"},
                           {"architecture": "arm64", "frames": [{"binaryUUID": str(uuid.uuid4()), "offset": True}]}]:
                with self.assertRaises(ValueError): symbols.symbolicate(report, root)

if __name__ == "__main__": unittest.main()
