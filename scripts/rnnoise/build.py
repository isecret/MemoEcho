#!/usr/bin/env python3
"""Build only the pinned RNNoise C core; no upstream build scripts are executed."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
LOCK_PATH = Path(__file__).with_name("source-lock.json")
SOURCES = ["celt_lpc", "denoise", "kiss_fft", "nnet", "nnet_default",
           "parse_lpcnet_weights", "pitch", "rnn", "rnnoise_tables", "rnnoise_data"]
ARCHITECTURES = ["arm64", "x86_64"]
DEFAULT_OUTPUT = ROOT / "app/MemoEcho/Resources/rnnoise"
# Shared flags keep isolated float/int8 benchmarks comparable. The default adds
# DISABLE_DEBUG_FLOAT, selecting mixed-int8 inference (user decision 2026-10-22).
CFLAGS = ["-O3", "-fPIC", "-dynamiclib", "-mmacosx-version-min=14.0",
          "-Wl,-install_name,@rpath/librnnoise.dylib"]


def run(*args):
    subprocess.run([str(arg) for arg in args], check=True)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def source_tree(lock, supplied):
    if supplied:
        source = supplied.resolve()
    else:
        checkout = ROOT / ".runtime" / "rnnoise" / lock["revision"]
        source = checkout / lock["subdirectory"]
        if not source.exists():
            checkout.parent.mkdir(parents=True, exist_ok=True)
            with tempfile.TemporaryDirectory(prefix="source-", dir=checkout.parent) as temp:
                run("git", "init", "--quiet", temp)
                run("git", "-C", temp, "remote", "add", "origin", lock["repository"])
                run("git", "-C", temp, "sparse-checkout", "set", lock["subdirectory"])
                run("git", "-C", temp, "fetch", "--quiet", "--depth=1", "--filter=blob:none",
                    "origin", lock["revision"])
                run("git", "-C", temp, "checkout", "--quiet", "--detach", "FETCH_HEAD")
                shutil.copytree(temp, checkout)
    return source


def snapshot_source(lock, source, destination):
    if lock["model_sha256"] != lock["files"]["src/rnnoise_data.c"]:
        raise SystemExit("RNNoise model hash disagrees with the source lock")
    # Compile only verified bytes. Extra headers in an offline source directory
    # must not shadow SDK headers, and edits after verification must not race us.
    for name, expected in lock["files"].items():
        path = source / name
        if not path.is_file() or path.is_symlink():
            raise SystemExit(f"RNNoise source checksum mismatch: {name}")
        content = path.read_bytes()
        if hashlib.sha256(content).hexdigest() != expected:
            raise SystemExit(f"RNNoise source checksum mismatch: {name}")
        target = destination / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(content)
    return destination


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-dir", type=Path, help="pinned external/rnnoise directory (offline build)")
    parser.add_argument("--output-dir", type=Path,
                        default=DEFAULT_OUTPUT)
    parser.add_argument("--inference", choices=["mixed-int8", "float"], default="mixed-int8",
                        help="mixed-int8 by default; float is only for isolated comparisons")
    args = parser.parse_args()
    if os.environ.get("RNNOISE_LIB_PATH"):
        parser.error("RNNOISE_LIB_PATH cannot establish source/model provenance; use --source-dir")
    output = args.output_dir.resolve()
    app_output = DEFAULT_OUTPUT.resolve()
    if args.inference == "float" and (output == app_output or app_output in output.parents):
        parser.error("float comparisons require --output-dir outside the app RNNoise resources")
    cflags = CFLAGS + (["-DDISABLE_DEBUG_FLOAT"] if args.inference == "mixed-int8" else [])
    lock = json.loads(LOCK_PATH.read_text())
    source = source_tree(lock, args.source_dir)
    sdk = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip()
    output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="build-", dir=output) as temp:
        build = Path(temp)
        source = snapshot_source(lock, source, build / "source")
        binaries = []
        for arch in ARCHITECTURES:
            binary = build / f"rnnoise-{arch}.dylib"
            run("xcrun", "--sdk", "macosx", "clang", *cflags, "-isysroot", sdk, "-arch", arch,
                "-I", source / "src", "-I", source / "include",
                *(source / "src" / f"{name}.c" for name in SOURCES), "-o", binary)
            binaries.append(binary)
        library = build / "librnnoise.dylib"
        run("xcrun", "lipo", "-create", *binaries, "-output", library)
        # Normal local build signing; release packaging uses Developer ID later.
        run("codesign", "--force", "--sign", "-", "--timestamp=none", library)
        run("codesign", "--verify", "--strict", library)
        run("python3", ROOT / "scripts/ci/verify-rnnoise.py", library)
        compiler = subprocess.check_output(["xcrun", "clang", "--version"], text=True).splitlines()[0]
        info = {"schema_version": 1, "repository": lock["repository"],
                "revision": lock["revision"], "source_lock_sha256": digest(LOCK_PATH),
                "model_sha256": lock["model_sha256"], "inference": args.inference,
                "architectures": ARCHITECTURES, "minimum_macos": "14.0",
                "frame_samples": 480, "sample_rate": 48000, "delay_samples": 960,
                "cflags": cflags, "compiler": compiler,
                "sdk": Path(sdk).name,
                "library_bytes": library.stat().st_size,
                "library_sha256_before_app_signing": digest(library)}
        (build / "build-info.json").write_text(json.dumps(info, indent=2) + "\n")
        for name in ["COPYING", "AUTHORS"]:
            shutil.copyfile(source / name, build / name)
        (output / "lib").mkdir(exist_ok=True)
        # Replace with our new build; never inherit downloaded-plugin metadata
        # or alter system security settings / quarantine attributes.
        os.replace(library, output / "lib/librnnoise.dylib")
        for name in ["COPYING", "AUTHORS", "build-info.json"]:
            os.replace(build / name, output / name)
        print(f"RNNoise core ready: {info['library_bytes']:,} bytes; {args.inference} inference; arm64 + x86_64")


if __name__ == "__main__":
    main()
