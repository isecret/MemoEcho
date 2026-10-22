#!/usr/bin/env python3
"""Statically validate the bundled RNNoise core without loading executable code.

Use --manifest to bind source resources to their build metadata. Omit it for
re-signed app bundles, because signing changes the artifact hash. Signature
verification and notarization remain the release pipeline's responsibility.
"""

import argparse
import hashlib
import json
from pathlib import Path
import struct
import sys


ARCHITECTURES = {0x0100000C: ("arm64", 0), 0x01000007: ("x86_64", 3)}
REQUIRED_SYMBOLS = {
    "_rnnoise_create", "_rnnoise_destroy", "_rnnoise_process_frame",
    "_rnnoise_get_frame_size",
}
FORBIDDEN_SYMBOL_FRAGMENTS = (
    "juce", "audiocomponentfactory", "audiounitfactory", "_audiounit",
    "vstpluginmain", "getpluginfactory", "clap_entry",
    "rnnoiseauentry", "rnnoiseaufactory", "rnnoiseaudioprocessor", "rnnoisecommonplugin",
)
INSTALL_NAME = "@rpath/librnnoise.dylib"
SYSTEM_LIBRARY = "/usr/lib/libSystem.B.dylib"
MAX_DEPLOYMENT_TARGET = 14 << 16
DYLIB_LOAD_COMMANDS = {0xC, 0x80000018, 0x8000001F, 0x20, 0x80000023}
LINKEDIT_DATA_COMMANDS = {0x1D, 0x26, 0x29, 0x2B, 0x2E, 0x80000033, 0x80000034}


class VerificationError(ValueError):
    pass


def require(condition, message):
    if not condition:
        raise VerificationError(message)


def region(data, offset, size, description):
    require(0 <= offset <= len(data) and 0 <= size <= len(data) - offset,
            f"truncated or out-of-bounds {description}")
    return data[offset:offset + size]


def c_string(data, offset, description):
    require(0 <= offset < len(data), f"invalid string offset in {description}")
    end = data.find(b"\0", offset)
    require(end >= 0, f"unterminated string in {description}")
    try:
        return data[offset:end].decode("utf-8")
    except UnicodeDecodeError as error:
        raise VerificationError(f"invalid UTF-8 in {description}") from error


def parse_slice(data, expected_cpu=None):
    endians = {b"\xcf\xfa\xed\xfe": "<", b"\xfe\xed\xfa\xcf": ">"}
    magic = bytes(data[:4])
    require(magic in endians, "expected a 64-bit Mach-O slice")
    endian = endians[magic]
    header = struct.unpack(endian + "8I", region(data, 0, 32, "Mach-O header"))
    _, cpu, subtype, filetype, ncmds, sizeofcmds, _, _ = header
    require(cpu in ARCHITECTURES, f"unsupported architecture: 0x{cpu:x}")
    name, required_subtype = ARCHITECTURES[cpu]
    require((subtype & 0x00FFFFFF) == required_subtype,
            f"{name}: unsupported CPU subtype")
    require(expected_cpu is None or expected_cpu == (cpu, subtype),
            f"{name}: fat header and Mach-O CPU disagree")
    require(filetype == 6, f"{name}: expected MH_DYLIB, got filetype {filetype}")
    region(data, 32, sizeofcmds, f"{name} load commands")
    require(ncmds <= sizeofcmds // 8, f"{name}: invalid load-command count")

    dependencies, install_names, targets, symtabs = [], [], [], []
    cursor, commands_end = 32, 32 + sizeofcmds
    for _ in range(ncmds):
        require(cursor + 8 <= commands_end, f"{name}: truncated load command")
        command, size = struct.unpack_from(endian + "II", data, cursor)
        require(size >= 8 and size % 8 == 0 and size <= commands_end - cursor,
                f"{name}: invalid load-command size")
        payload = data[cursor:cursor + size]
        if command == 0xD or command in DYLIB_LOAD_COMMANDS:
            region(payload, 0, 24, "dylib load command")
            string_offset = struct.unpack_from(endian + "I", payload, 8)[0]
            require(string_offset >= 24, f"{name}: invalid dylib name offset")
            library = c_string(payload, string_offset, "dylib load command")
            (install_names if command == 0xD else dependencies).append(library)
        elif command == 0x32:  # LC_BUILD_VERSION
            _, _, platform, minimum, _, ntools = struct.unpack(
                endian + "6I", region(payload, 0, 24, "LC_BUILD_VERSION"))
            require(platform == 1, f"{name}: build platform must be macOS")
            region(payload, 24, ntools * 8, "build tools")
            targets.append(minimum)
        elif command == 0x24:  # LC_VERSION_MIN_MACOSX (older toolchains)
            _, _, minimum, _ = struct.unpack(
                endian + "4I", region(payload, 0, 16, "LC_VERSION_MIN_MACOSX"))
            targets.append(minimum)
        elif command == 0x2:  # LC_SYMTAB
            symtabs.append(struct.unpack(endian + "6I",
                                         region(payload, 0, 24, "LC_SYMTAB"))[2:])
        elif command == 0x19:  # LC_SEGMENT_64: detect truncated mapped data
            region(payload, 0, 72, "LC_SEGMENT_64")
            file_offset, file_size = struct.unpack_from(endian + "QQ", payload, 40)
            section_count = struct.unpack_from(endian + "I", payload, 64)[0]
            region(payload, 72, section_count * 80, "segment sections")
            region(data, file_offset, file_size, "segment data")
        elif command in LINKEDIT_DATA_COMMANDS:
            _, _, offset, count = struct.unpack(
                endian + "4I", region(payload, 0, 16, "linkedit command"))
            region(data, offset, count, "linkedit data")
        cursor += size

    require(cursor == commands_end, f"{name}: load-command size mismatch")
    require(install_names == [INSTALL_NAME], f"{name}: install_name must be {INSTALL_NAME}")
    require(dependencies == [SYSTEM_LIBRARY],
            f"{name}: only dependency must be {SYSTEM_LIBRARY}; got {dependencies}")
    require(len(targets) == 1 and 0 < targets[0] <= MAX_DEPLOYMENT_TARGET,
            f"{name}: requires one macOS deployment target no newer than 14.0")
    require(len(symtabs) == 1, f"{name}: expected one symbol table")
    symbol_offset, symbol_count, string_offset, string_size = symtabs[0]
    symbol_data = region(data, symbol_offset, symbol_count * 16, "symbol table")
    strings = region(data, string_offset, string_size, "string table")
    exported = set()
    for index in range(symbol_count):
        string_index, kind, section, _, _ = struct.unpack_from(
            endian + "IBBHQ", symbol_data, index * 16)
        symbol = c_string(strings, string_index, "symbol table")
        require(not any(fragment in symbol.lower() for fragment in FORBIDDEN_SYMBOL_FRAGMENTS),
                f"{name}: plugin/UI symbol is forbidden: {symbol}")
        # N_EXT + defined N_SECT, excluding N_STAB and N_PEXT debug/private symbols.
        if kind & 0xF0 == 0 and kind & 1 and kind & 0x0E == 0x0E and section:
            exported.add(symbol)
    missing = REQUIRED_SYMBOLS - exported
    require(not missing, f"{name}: missing exported RNNoise API: {', '.join(sorted(missing))}")
    return name


def verify_bytes(data):
    fat_formats = {
        b"\xca\xfe\xba\xbe": (">", False), b"\xbe\xba\xfe\xca": ("<", False),
        b"\xca\xfe\xba\xbf": (">", True), b"\xbf\xba\xfe\xca": ("<", True),
    }
    magic = bytes(data[:4])
    if magic not in fat_formats:
        architectures = [parse_slice(data)]
    else:
        endian, fat64 = fat_formats[magic]
        _, count = struct.unpack(endian + "II", region(data, 0, 8, "fat header"))
        entry_size = 32 if fat64 else 20
        table_end = 8 + count * entry_size
        region(data, 8, count * entry_size, "fat architecture table")
        architectures, ranges = [], []
        for index in range(count):
            entry = struct.unpack_from(endian + ("IIQQII" if fat64 else "5I"),
                                       data, 8 + index * entry_size)
            cpu, subtype, offset, size, alignment = entry[:5]
            require(offset >= table_end, "fat slice overlaps architecture table")
            require(alignment <= 31 and offset % (1 << alignment) == 0,
                    "invalid fat slice alignment")
            require(all(offset >= end or offset + size <= start for start, end in ranges),
                    "overlapping fat slices")
            ranges.append((offset, offset + size))
            architectures.append(parse_slice(region(data, offset, size, "fat slice"),
                                               (cpu, subtype)))
    require(sorted(architectures) == ["arm64", "x86_64"],
            f"requires exactly arm64 and x86_64 slices; got {architectures}")
    return architectures


def verify_manifest(data, path):
    try:
        manifest = json.loads(path.read_text(encoding="utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise VerificationError("invalid build manifest JSON") from error
    require(isinstance(manifest, dict), "build manifest must be a JSON object")
    require(type(manifest.get("schema_version")) is int and manifest["schema_version"] == 1,
            "build manifest schema_version must be 1")
    require(manifest.get("inference") == "mixed-int8", "build manifest inference must be mixed-int8")
    flags = manifest.get("cflags")
    require(isinstance(flags, list) and "-DDISABLE_DEBUG_FLOAT" in flags,
            "build manifest must enable DISABLE_DEBUG_FLOAT")
    architectures = manifest.get("architectures")
    require(architectures in (["arm64", "x86_64"], ["x86_64", "arm64"]),
            "build manifest requires exactly arm64 and x86_64")
    require(type(manifest.get("library_bytes")) is int and manifest["library_bytes"] == len(data),
            "source library size disagrees with build manifest")
    require(manifest.get("library_sha256_before_app_signing") == hashlib.sha256(data).hexdigest(),
            "source library SHA-256 disagrees with build manifest")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("library", type=Path, help="path to librnnoise.dylib")
    parser.add_argument("--manifest", type=Path,
                        help="source build-info.json; omit after app signing")
    args = parser.parse_args()
    try:
        data = args.library.read_bytes()
        verify_bytes(data)
        if args.manifest:
            verify_manifest(data, args.manifest)
    except (OSError, VerificationError) as error:
        print(f"error: RNNoise validation failed: {error}", file=sys.stderr)
        return 1
    print("RNNoise core verified: arm64 + x86_64, MH_DYLIB, libSystem only, macOS 14 compatible")
    if args.manifest:
        print("RNNoise source artifact matches its mixed-int8 build manifest")
    return 0


if __name__ == "__main__":
    sys.exit(main())
