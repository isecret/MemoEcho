#!/usr/bin/env python3
"""Strip local symbols from archived ASR libraries before final code signing.

Source libraries remain untouched for debugging. Stage both outputs and check
every architecture's exported API before replacing anything in the app bundle.
"""
import argparse
from pathlib import Path
import shutil
import subprocess
import tempfile


LIBRARIES = ("libonnxruntime.1.24.4.dylib", "libsherpa-onnx-c-api.dylib")


def run_tool(*arguments):
    return subprocess.check_output(["xcrun", *map(str, arguments)], text=True)


def exported_api(path):
    architectures = sorted(run_tool("lipo", "-archs", path).split())
    if architectures != ["arm64", "x86_64"]:
        raise ValueError(f"Expected arm64 + x86_64 runtime: {path}")
    result = {}
    for architecture in architectures:
        symbols = sorted(run_tool("nm", "-arch", architecture, "-gjU", path).splitlines())
        if not symbols:
            raise ValueError(f"Runtime has no exported symbols ({architecture}): {path}")
        result[architecture] = symbols
    return result


def strip_runtime(app):
    if app.suffix != ".app" or not (app / "Contents").is_dir():
        raise ValueError(f"Expected an app bundle, not a source resource directory: {app}")
    root = app / "Contents/Resources/sherpa-onnx/lib"
    paths = [root / name for name in LIBRARIES]
    for path in paths:
        if path.is_symlink() or not path.is_file():
            raise ValueError(f"Expected a regular runtime library: {path}")
        if not path.resolve().is_relative_to(app.resolve()):
            raise ValueError(f"Runtime library is outside the app bundle: {path}")

    changes = []
    with tempfile.TemporaryDirectory(prefix=".strip-asr-", dir=root) as temporary:
        for path in paths:
            before = exported_api(path)
            candidate = Path(temporary) / path.name
            shutil.copy2(path, candidate)
            run_tool("strip", "-x", candidate)
            if exported_api(candidate) != before:
                raise ValueError(f"Refusing to change exported runtime API: {path}")
            changes.append((path.name, path.stat().st_size, candidate.stat().st_size))
        # Only publish candidates once both libraries passed validation.
        for path in paths:
            (Path(temporary) / path.name).replace(path)
    return changes


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    args = parser.parse_args()
    try:
        for name, before, after in strip_runtime(args.app):
            print(f"Stripped {name}: {before:,} -> {after:,} bytes; exported API unchanged")
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"error: {error}\n")


if __name__ == "__main__":
    main()
