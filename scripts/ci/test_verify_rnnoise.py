#!/usr/bin/env python3
"""Synthetic Mach-O fixtures only; these tests never load or execute a library."""

import importlib.util
import hashlib
import json
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("verify-rnnoise.py")
SPEC = importlib.util.spec_from_file_location("verify_rnnoise", SCRIPT)
VERIFY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(VERIFY)
ARM64, X86_64 = 0x0100000C, 0x01000007
SYMBOLS = sorted(VERIFY.REQUIRED_SYMBOLS)


def dylib_command(command, name, endian):
    value = name.encode() + b"\0"
    size = (24 + len(value) + 7) // 8 * 8
    return struct.pack(endian + "6I", command, size, 24, 0, 0, 0) + value.ljust(size - 24, b"\0")


def thin(cpu=ARM64, *, filetype=6, dependencies=(VERIFY.SYSTEM_LIBRARY,),
         install_name=VERIFY.INSTALL_NAME, symbols=SYMBOLS, symbol_kind=0xF,
         target=14 << 16, platform=1, endian="<", legacy_target=False):
    commands = [dylib_command(0xD, install_name, endian)]
    commands.extend(dylib_command(0xC, name, endian) for name in dependencies)
    if legacy_target:
        commands.append(struct.pack(endian + "4I", 0x24, 16, target, 0))
    else:
        commands.append(struct.pack(endian + "6I", 0x32, 24, platform, target, 0, 0))
    string_table, symbol_table = bytearray(b"\0"), bytearray()
    for symbol in symbols:
        symbol_table.extend(struct.pack(endian + "IBBHQ", len(string_table), symbol_kind, 1, 0, 1))
        string_table.extend(symbol.encode() + b"\0")
    command_size = sum(map(len, commands)) + 24
    symbol_offset = 32 + command_size
    commands.append(struct.pack(endian + "6I", 2, 24, symbol_offset, len(symbols),
                                symbol_offset + len(symbol_table), len(string_table)))
    header = struct.pack(endian + "8I", 0xFEEDFACF, cpu, 0 if cpu == ARM64 else 3,
                         filetype, len(commands), command_size, 0, 0)
    return header + b"".join(commands) + symbol_table + string_table


def fat(slices=None, *, endian=">", fat64=False):
    slices = slices or [(ARM64, thin()), (X86_64, thin(X86_64))]
    entry_size = 32 if fat64 else 20
    offset = 8 + len(slices) * entry_size
    table, content = bytearray(), bytearray()
    for cpu, data in slices:
        values = [cpu, 0 if cpu == ARM64 else 3, offset, len(data), 0]
        if fat64:
            values.append(0)
        table.extend(struct.pack(endian + ("IIQQII" if fat64 else "5I"), *values))
        content.extend(data)
        offset += len(data)
    return struct.pack(endian + "II", 0xCAFEBABF if fat64 else 0xCAFEBABE,
                       len(slices)) + table + content


def build_manifest(data):
    return {"schema_version": 1, "inference": "mixed-int8", "cflags": ["-DDISABLE_DEBUG_FLOAT"],
            "architectures": ["arm64", "x86_64"], "library_bytes": len(data),
            "library_sha256_before_app_signing": hashlib.sha256(data).hexdigest()}


class RNNoiseValidationTests(unittest.TestCase):
    def assert_invalid(self, data, message):
        with self.assertRaisesRegex(VERIFY.VerificationError, message):
            VERIFY.verify_bytes(data)

    def test_core_universal_binary(self):
        self.assertEqual(VERIFY.verify_bytes(fat()), ["arm64", "x86_64"])

    def test_fat64_and_both_byte_orders(self):
        for endian in ("<", ">"):
            for fat64 in (False, True):
                with self.subTest(endian=endian, fat64=fat64):
                    binary = fat([(ARM64, thin(endian=endian)),
                                  (X86_64, thin(X86_64, endian=endian))],
                                 endian=endian, fat64=fat64)
                    self.assertEqual(VERIFY.verify_bytes(binary), ["arm64", "x86_64"])

    def test_old_plugin_bundle_is_rejected(self):
        self.assert_invalid(fat([(ARM64, thin(filetype=8)), (X86_64, thin(X86_64))]), "MH_DYLIB")

    def test_missing_or_duplicate_architecture(self):
        for data in (thin(), fat([(ARM64, thin())]), fat([(ARM64, thin()), (ARM64, thin())])):
            self.assert_invalid(data, "exactly arm64 and x86_64")

    def test_fat_header_must_match_slice(self):
        self.assert_invalid(fat([(ARM64, thin(X86_64)), (X86_64, thin(X86_64))]), "CPU disagree")

    def test_non_system_and_missing_dependencies(self):
        for dependencies in ((), (VERIFY.SYSTEM_LIBRARY, "/System/Library/Frameworks/AppKit.framework/AppKit"),
                             ("@rpath/libextra.dylib",)):
            self.assert_invalid(fat([(ARM64, thin(dependencies=dependencies)),
                                     (X86_64, thin(X86_64))]), "only dependency")

    def test_wrong_install_name(self):
        self.assert_invalid(fat([(ARM64, thin(install_name="/tmp/librnnoise.dylib")),
                                 (X86_64, thin(X86_64))]), "install_name")

    def test_missing_or_private_or_undefined_api(self):
        for data in (thin(symbols=SYMBOLS[:-1]), thin(symbol_kind=0x1F), thin(symbol_kind=0x1)):
            self.assert_invalid(fat([(ARM64, data), (X86_64, thin(X86_64))]), "missing exported")

    def test_ui_plugin_symbols(self):
        for symbol in ("__ZN4juce12MessageManagerE", "_AudioComponentFactory", "_VSTPluginMain",
                       "_rnnoiseAUEntry", "_rnnoiseAUFactory", "__Z22RnNoiseAudioProcessor",
                       "__Z18RnNoiseCommonPlugin"):
            self.assert_invalid(fat([(ARM64, thin(symbols=SYMBOLS + [symbol])),
                                     (X86_64, thin(X86_64))]), "plugin/UI symbol")

    def test_macos_minimum_version_and_platform(self):
        for data in (thin(target=15 << 16), thin(target=0), thin(platform=2)):
            self.assert_invalid(fat([(ARM64, data), (X86_64, thin(X86_64))]), "macOS")
        self.assertEqual(VERIFY.parse_slice(thin(legacy_target=True)), "arm64")

    def test_truncation_at_headers_commands_and_tables(self):
        binary = fat()
        for length in (0, 4, 7, 20, 47, len(binary) - 1):
            with self.subTest(length=length):
                with self.assertRaises(VERIFY.VerificationError):
                    VERIFY.verify_bytes(binary[:length])
        with self.assertRaises(VERIFY.VerificationError):
            VERIFY.parse_slice(thin()[:-1])

    def test_malformed_command_and_string(self):
        data = bytearray(thin())
        struct.pack_into("<I", data, 36, 0)
        self.assert_invalid(fat([(ARM64, data), (X86_64, thin(X86_64))]), "load-command size")
        data = bytearray(thin())
        data[-1] = 65
        self.assert_invalid(fat([(ARM64, data), (X86_64, thin(X86_64))]), "unterminated string")

    def test_overlapping_fat_slices(self):
        data = bytearray(fat())
        first_offset = struct.unpack_from(">I", data, 16)[0]
        struct.pack_into(">I", data, 36, first_offset)
        self.assert_invalid(data, "overlapping fat slices")

    def test_cli_success_and_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            library = Path(directory) / "librnnoise.dylib"
            for data, expected in ((fat(), 0), (thin(), 1)):
                library.write_bytes(data)
                result = subprocess.run([sys.executable, str(SCRIPT), str(library)],
                                        capture_output=True, text=True, timeout=5)
                self.assertEqual(result.returncode, expected, result.stderr)
                if expected:
                    self.assertIn("error: RNNoise validation failed", result.stderr)

    def assert_manifest_result(self, document, expected, error=None):
        data = fat()
        with tempfile.TemporaryDirectory() as directory:
            library = Path(directory) / "librnnoise.dylib"
            manifest = Path(directory) / "build-info.json"
            library.write_bytes(data)
            if document is not None:
                manifest.write_text(document if isinstance(document, str) else json.dumps(document),
                                    encoding="utf-8")
            result = subprocess.run([sys.executable, str(SCRIPT), str(library),
                                     "--manifest", str(manifest)],
                                    capture_output=True, text=True, timeout=5)
            self.assertEqual(result.returncode, expected, result.stderr)
            self.assertEqual(library.read_bytes(), data, "validation must not modify the library")
            if error:
                self.assertIn(error, result.stderr)

    def test_source_manifest_matches_artifact(self):
        self.assert_manifest_result(build_manifest(fat()), 0)

    def test_source_manifest_rejects_wrong_hash_or_size(self):
        for field, value, error in (
            ("library_sha256_before_app_signing", "0" * 64, "SHA-256 disagrees"),
            ("library_bytes", len(fat()) + 1, "size disagrees"),
        ):
            with self.subTest(field=field):
                manifest = build_manifest(fat())
                manifest[field] = value
                self.assert_manifest_result(manifest, 1, error)

    def test_source_manifest_rejects_float_or_invalid_metadata(self):
        for field, value, error in (
            ("inference", "float", "inference must be mixed-int8"),
            ("inference", "int8", "inference must be mixed-int8"),
            ("inference", "mixed-int8-experimental", "inference must be mixed-int8"),
            ("cflags", [], "must enable DISABLE_DEBUG_FLOAT"),
            ("cflags", None, "must enable DISABLE_DEBUG_FLOAT"),
            ("cflags", "-DDISABLE_DEBUG_FLOAT", "must enable DISABLE_DEBUG_FLOAT"),
            ("schema_version", 2, "schema_version must be 1"),
            ("schema_version", True, "schema_version must be 1"),
            ("architectures", ["arm64"], "exactly arm64 and x86_64"),
            ("architectures", ["arm64", "arm64"], "exactly arm64 and x86_64"),
        ):
            with self.subTest(field=field, value=value):
                manifest = build_manifest(fat())
                manifest[field] = value
                self.assert_manifest_result(manifest, 1, error)

    def test_source_manifest_missing_or_malformed(self):
        self.assert_manifest_result(None, 1, "error: RNNoise validation failed")
        self.assert_manifest_result("{invalid JSON", 1, "invalid build manifest JSON")
        self.assert_manifest_result("[]", 1, "build manifest must be a JSON object")


if __name__ == "__main__":
    unittest.main()
