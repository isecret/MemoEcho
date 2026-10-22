#!/usr/bin/env python3
"""Compare isolated float and mixed-int8 builds; never replace app resources."""
import argparse
import json
from pathlib import Path
import platform
import statistics
import subprocess
import sys
import time
import wave

import build as core

ROOT = core.ROOT
WORK = ROOT / ".runtime/rnnoise/quantized-evaluation"
APP_LIBRARY = ROOT / "app/MemoEcho/Resources/rnnoise/lib/librnnoise.dylib"
FLOAT = WORK / "float/lib/librnnoise.dylib"
INT8 = WORK / "int8/lib/librnnoise.dylib"
PROBE = WORK / "benchmark"


def capture(*args):
    return subprocess.check_output([str(x) for x in args], text=True).strip()


def prepare():
    WORK.mkdir(parents=True, exist_ok=True)
    sdk = capture("xcrun", "--sdk", "macosx", "--show-sdk-path")
    compiler = capture("xcrun", "clang", "--version").splitlines()[0]
    for inference, library in [("float", FLOAT), ("mixed-int8", INT8)]:
        core.run(sys.executable, Path(core.__file__), "--inference", inference,
                 "--output-dir", library.parents[1])
    for variant, info in validate_libraries().items():
        if info["compiler"] != compiler or info["sdk"] != Path(sdk).name:
            raise SystemExit(f"{variant} build changed toolchain during preparation")
    core.run("xcrun", "swiftc", "-O", "-swift-version", "6", "-sdk", sdk,
             "-target", "arm64-apple-macosx14.0",
             ROOT / "app/MemoEcho/Platform/StreamingAudioPreprocessor.swift",
             Path(__file__).with_suffix(".swift"), "-o", PROBE)
    core.run("codesign", "--sign", "-", "--timestamp=none", PROBE)
    (WORK / "probe-build-info.json").write_text(json.dumps({
        "probe_sha256": core.digest(PROBE),
        "source_sha256": core.digest(Path(__file__).with_suffix(".swift")),
        "pipeline_sha256": core.digest(ROOT / "app/MemoEcho/Platform/StreamingAudioPreprocessor.swift"),
        "swift_flags": ["-O", "-swift-version", "6", "-target", "arm64-apple-macosx14.0"],
        "sdk": Path(sdk).name,
    }, indent=2)+"\n")


def validate_libraries():
    lock = json.loads(core.LOCK_PATH.read_text())
    builds = {}
    for variant, inference, library in [("float", "float", FLOAT), ("int8", "mixed-int8", INT8)]:
        info = json.loads((library.parents[1] / "build-info.json").read_text())
        expected = {"schema_version": 1, "inference": inference,
                    "revision": lock["revision"], "model_sha256": lock["model_sha256"],
                    "source_lock_sha256": core.digest(core.LOCK_PATH),
                    "architectures": core.ARCHITECTURES,
                    "cflags": core.CFLAGS + (["-DDISABLE_DEBUG_FLOAT"] if variant == "int8" else []),
                    "library_bytes": library.stat().st_size,
                    "library_sha256_before_app_signing": core.digest(library)}
        for key, value in expected.items():
            if info.get(key) != value:
                raise SystemExit(f"{variant} build mismatch for {key}; run prepare again")
        builds[variant] = info
    for key in ["compiler", "sdk"]:
        if not builds["float"].get(key) or builds["float"][key] != builds["int8"].get(key):
            raise SystemExit(f"Float/int8 build mismatch for {key}; use the same toolchain")
    return builds


def validate_artifacts():
    builds = validate_libraries()
    probe = json.loads((WORK / "probe-build-info.json").read_text())
    expected = {"probe_sha256": core.digest(PROBE),
                "source_sha256": core.digest(Path(__file__).with_suffix(".swift")),
                "pipeline_sha256": core.digest(ROOT / "app/MemoEcho/Platform/StreamingAudioPreprocessor.swift"),
                "sdk": builds["float"]["sdk"]}
    for key, value in expected.items():
        if probe.get(key) != value:
            raise SystemExit(f"Probe mismatch for {key}; run prepare again")
    return {**builds, "probe": probe}


def fixtures():
    import numpy as np
    original = ROOT / "app/MemoEcho/Resources/ASRValidation/asr-validation.wav"
    with wave.open(str(original), "rb") as reader:
        assert (reader.getnchannels(), reader.getsampwidth(), reader.getframerate()) == (1, 2, 16000)
        speech = np.frombuffer(reader.readframes(reader.getnframes()), dtype="<i2").astype(np.float64)
    speech = np.resize(speech, 55*16000)
    # Same fixed speechlike workload for both builds. White noise at 10 dB
    # relative to whole-file RMS; this is performance input, not a quality score.
    rng = np.random.default_rng(22022)
    noise = rng.standard_normal(len(speech))
    noise *= np.sqrt(np.mean(speech**2))/np.sqrt(np.mean(noise**2))/np.sqrt(10)
    mixed = speech+noise
    mixed *= min(1, 30000/np.max(np.abs(mixed)))
    for name, samples in [("speech-noise", mixed), ("silence", np.zeros(len(mixed)))]:
        with wave.open(str(WORK / f"{name}.wav"), "wb") as writer:
            writer.setparams((1, 2, 16000, 0, "NONE", "not compressed"))
            writer.writeframes(np.rint(samples).astype("<i2").tobytes())


def measure(trials):
    builds = validate_artifacts()
    fixtures()
    records = []
    # ABBA order in adjacent pairs, each observation in a fresh process.
    for condition in ["speech-noise", "silence"]:
        for mode in ["core", "pipeline"]:
            count = trials if condition == "speech-noise" else 2
            for trial in range(count):
                order = [("float", FLOAT), ("int8", INT8)]
                if trial % 2: order.reverse()
                for variant, library in order:
                    result = json.loads(capture(PROBE, library, mode, WORK / f"{condition}.wav"))
                    result.update(variant=variant, trial=trial, condition=condition)
                    records.append(result)
                    print(f"{condition} {mode} #{trial+1} {variant}: CPU {result['cpu_seconds']:.4f}s, RSS {result['peak_rss_bytes']/2**20:.2f}MiB", flush=True)
    report = {"schema_version": 1, "created_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
              "machine": capture("sysctl", "-n", "machdep.cpu.brand_string"),
              "os": platform.platform(), "swift": capture("xcrun", "swiftc", "--version"),
              "source_lock_sha256": core.digest(core.LOCK_PATH),
              "pipeline_sha256": core.digest(ROOT / "app/MemoEcho/Platform/StreamingAudioPreprocessor.swift"),
              "probe_sha256": core.digest(Path(__file__).with_suffix(".swift")),
              "workload_sha256": core.digest(WORK / "speech-noise.wav"),
              "power": capture("pmset", "-g", "batt"),
              "thermal": capture("pmset", "-g", "therm"),
              "libraries": {name: {"bytes": path.stat().st_size, "sha256": core.digest(path)}
                            for name, path in [("float", FLOAT), ("int8", INT8)]},
              "builds": builds,
              "records": records, "summaries": []}
    for condition in ["speech-noise", "silence"]:
        for mode in ["core", "pipeline"]:
            selected = [r for r in records if r["condition"] == condition and r["mode"] == mode]
            summary = {"condition": condition, "mode": mode}
            for variant in ["float", "int8"]:
                rows = [r for r in selected if r["variant"] == variant]
                summary[variant] = {key: {"median": statistics.median(r[key] for r in rows),
                                         "min": min(r[key] for r in rows), "max": max(r[key] for r in rows)}
                                    for key in ["cpu_seconds", "wall_seconds", "cpu_realtime_factor",
                                                "call_p95_ms", "peak_rss_bytes", "peak_rss_before_load_bytes",
                                                "resident_before_load_bytes", "resident_after_warmup_bytes",
                                                "resident_after_processing_bytes",
                                                "load_seconds"]}
            floats = {r["trial"]: r for r in selected if r["variant"] == "float"}
            ratios = [r["cpu_seconds"]/floats[r["trial"]]["cpu_seconds"] for r in selected if r["variant"] == "int8"]
            summary["paired_cpu_ratio_median"] = statistics.median(ratios)
            report["summaries"].append(summary)
    (WORK / "performance.json").write_text(json.dumps(report, indent=2)+"\n")


def process_corpus():
    validate_artifacts()
    manifest = json.loads((WORK / "quality/manifest.json").read_text())
    for variant, library in [("float", FLOAT), ("int8", INT8)]:
        directory = WORK / f"quality/{variant}"
        directory.mkdir(exist_ok=True)
        for case in manifest["cases"]:
            subprocess.run([str(PROBE), str(library), "process", case["input_path"],
                            str(directory / f"{case['id']}.wav")], check=True)
        print(f"Processed {len(manifest['cases'])} {variant} WAV files", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["prepare", "measure", "process"])
    parser.add_argument("--trials", type=int, default=8)
    args = parser.parse_args()
    if args.trials < 2 or args.trials % 2:
        parser.error("--trials must be an even number >= 2 for balanced order")
    original = core.digest(APP_LIBRARY)
    try:
        if args.action == "prepare": prepare()
        elif args.action == "measure": measure(args.trials)
        else: process_corpus()
    finally:
        if core.digest(APP_LIBRARY) != original:
            raise SystemExit("Default app library changed during experiment")


if __name__ == "__main__":
    main()
