#!/usr/bin/env python3
"""Synthetic Chinese RNNoise quality probe; never records or calls cloud ASR.

prepare: synthesize with installed macOS say voices and fixed artificial noise.
decode: load local SenseVoice once; retain every transcript and CER comparison.
This small synthetic corpus is a regression probe, not real-speech acceptance.
"""
import argparse
import hashlib
import json
import math
from pathlib import Path
import platform
import re
import subprocess
import unicodedata
import wave

import numpy as np
from scipy.io import wavfile
from scipy.signal import butter, resample_poly, sosfilt


ROOT = Path(__file__).resolve().parents[2]
DEFAULT_OUTPUT = ROOT / ".runtime/rnnoise/quantized-evaluation/quality"
RATE = 16000
SEED = 20261022
VOICES = [("tingting", "Tingting (中文（中国大陆）)"),
          ("eddy", "Eddy (中文（中国大陆）)")]
UTTERANCES = [
    ("daily", "请把今天的会议纪要发给项目组，我们明天上午继续讨论。"),
    ("short_tail", "这份资料已经检查过了，最后一页请保留原来的备注。"),
    ("near_sounds", "司机试着轻声解释，支持和实施是两个不同的词。"),
    ("numbers", "请在下午三点二十五分提醒我，预算是一千二百八十元。"),
    ("digit_sequence", "订单编号是五八二七，验证码是六九三一，请再确认一次。"),
    ("mixed_english", "请打开 Safari，检查 API 返回的 JSON，然后保存文件。"),
]
CONDITIONS = [
    ("clean", None, None, 0),
    ("steady10dB", "steady", 10, 0),
    ("steady0dB", "steady", 0, 0),
    ("transient10dB", "transient", 10, 0),
    ("quiet", None, None, -18),
    ("quiet_steady10dB", "steady", 10, -18),
]
NORMALIZATION = (
    "NFKC; remove SenseVoice control tags <|...|>; lowercase Latin; convert Chinese "
    "numeral runs (零〇一二两三四五六七八九十百千万亿) to Arabic, including digit "
    "sequences; remove Unicode punctuation, symbols and whitespace. Every remaining "
    "Unicode code point (including Latin letters/digits) counts as one character. "
    "Same fixed rules apply to references and hypotheses, without transcript-specific edits."
)


def sha256(path):
    with path.open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2, ensure_ascii=False) + "\n")


def read_wav(path):
    with wave.open(str(path), "rb") as source:
        if source.getnchannels() != 1 or source.getsampwidth() != 2:
            raise ValueError(f"Expected mono PCM16 WAV: {path}")
        samples = np.frombuffer(source.readframes(source.getnframes()), dtype="<i2")
        return source.getframerate(), samples.astype(np.float64) / 32768.0


def write_wav(path, samples):
    if not np.isfinite(samples).all() or np.max(np.abs(samples)) >= 1:
        raise ValueError(f"Non-finite or clipping audio: {path}")
    wavfile.write(path, RATE, np.rint(samples * 32767).astype(np.int16))


def speech_mask(samples):
    # 20 ms block RMS above -35 dB relative to the loudest block. Noise scaling
    # uses this clean-speech mask (before padding), never a noisy-signal VAD.
    block = RATE // 50
    padded = np.pad(samples, (0, (-len(samples)) % block))
    rms = np.sqrt(np.mean(padded.reshape(-1, block) ** 2, axis=1))
    return np.repeat(rms >= rms.max() * 10 ** (-35 / 20), block)[:len(samples)]


def noise_samples(kind, count, rng):
    if kind == "steady":
        # Artificial fan-like low-pass Gaussian noise, with quiet mains hum.
        low = sosfilt(butter(2, 1800, fs=RATE, output="sos"), rng.standard_normal(count))
        return low + 0.12 * np.sin(2 * np.pi * 100 * np.arange(count) / RATE)
    noise = np.zeros(count)
    # Artificial keyboard-like decaying broadband impulses, not a real recording.
    for start in rng.integers(0, count, size=max(1, int(count / RATE * 4))):
        length = min(int(RATE * 0.035), count - start)
        impulse = rng.standard_normal(length) * np.exp(-np.arange(length) / (RATE * 0.006))
        noise[start:start + length] += impulse
    return noise


def prepare(output):
    output.mkdir(parents=True, exist_ok=True)
    source_dir, input_dir = output / "source", output / "input"
    source_dir.mkdir(exist_ok=True)
    input_dir.mkdir(exist_ok=True)
    available = subprocess.check_output(["say", "-v", "?"], text=True)
    cases = []
    for voice_index, (voice_id, voice) in enumerate(VOICES):
        if voice not in available:
            raise SystemExit(f"Required installed voice missing: {voice}")
        for text_index, (category, reference) in enumerate(UTTERANCES, 1):
            utterance_id = f"{voice_id}_{text_index:02d}"
            source = source_dir / f"{utterance_id}.wav"
            subprocess.run(["say", "-v", voice, "-r", "165", "-o", str(source),
                            "--file-format=WAVE", "--data-format=LEI16@22050", reference],
                           check=True)
            source_rate, samples = read_wav(source)
            gcd = math.gcd(source_rate, RATE)
            samples = resample_poly(samples, RATE // gcd, source_rate // gcd)
            # Fixed per-utterance clean RMS at -24 dBFS over the activity mask.
            mask = speech_mask(samples)
            source_rms = float(np.sqrt(np.mean(samples[mask] ** 2)))
            rms_gain = 10 ** (-24 / 20) / source_rms
            samples *= rms_gain
            padding = RATE // 2
            clean = np.pad(samples, (padding, padding))
            mask = np.pad(mask, (padding, padding))
            for condition_index, (condition, kind, snr, gain_db) in enumerate(CONDITIONS):
                case_id = f"{utterance_id}__{condition}"
                seed = SEED + voice_index * 10000 + text_index * 100 + condition_index
                speech = clean * 10 ** (gain_db / 20)
                noise = np.zeros_like(speech)
                if kind:
                    noise = noise_samples(kind, len(speech), np.random.default_rng(seed))
                    noise *= (np.sqrt(np.mean(speech[mask] ** 2)) /
                              np.sqrt(np.mean(noise[mask] ** 2)) / 10 ** (snr / 20))
                mixture = speech + noise
                # A common gain on speech and noise preserves SNR and avoids clipping.
                anti_clip_gain = min(1.0, 0.95 / max(float(np.max(np.abs(mixture))), 1e-10))
                mixture *= anti_clip_gain
                destination = input_dir / f"{case_id}.wav"
                write_wav(destination, mixture)
                cases.append({
                    "id": case_id, "utterance_id": utterance_id, "voice": voice,
                    "category": category, "reference": reference, "condition": condition,
                    "input_path": str(destination.resolve()),
                    "input_sha256": sha256(destination), "source_sha256": sha256(source),
                    "duration_seconds": len(mixture) / RATE, "samples": len(mixture),
                    "sample_rate": RATE, "snr_db": snr, "speech_gain_db": gain_db,
                    "speech_rms_dbfs": -24 + gain_db + 20 * math.log10(anti_clip_gain),
                    "anti_clip_gain": anti_clip_gain, "synthesis_rms_gain": rms_gain,
                    "seed": seed, "peak": float(np.max(np.abs(mixture))),
                })
    manifest = {
        "schema_version": 1, "sample_rate": RATE, "seed": SEED,
        "source": "macOS say, installed Mandarin voices; no microphone or user recordings",
        "os": platform.platform(), "synthesis_rate": 165,
        "source_sample_rate": 22050, "resampling": "scipy.signal.resample_poly",
        "padding_seconds_each_end": 0.5, "clean_active_rms_dbfs": -24,
        "activity_mask": "20ms clean blocks with RMS >= peak block RMS -35dB",
        "snr_definition": "speech/noise RMS over the clean activity mask; same gain prevents clipping",
        "noise": {"steady": "synthetic 1800Hz low-pass Gaussian + 100Hz sine",
                  "transient": "synthetic decaying broadband impulses at 4 per second (not real keyboard recordings)"},
        "cases": cases,
    }
    write_json(output / "manifest.json", manifest)
    (output / "input-paths.txt").write_text("".join(case["input_path"] + "\n" for case in cases))
    print(json.dumps({"manifest": str(output / "manifest.json"), "cases": len(cases),
                      "seconds": sum(case["duration_seconds"] for case in cases)}))


def chinese_number(match):
    value = match.group()
    digits = {character: number for number, character in enumerate("零一二三四五六七八九")}
    digits.update({"〇": 0, "两": 2})
    units = {"十": 10, "百": 100, "千": 1000, "万": 10000, "亿": 100000000}
    if not any(character in units for character in value):
        return "".join(str(digits[character]) for character in value)
    total, section, number = 0, 0, 0
    for character in value:
        if character in digits:
            number = digits[character]
        elif units[character] < 10000:
            section += (number or 1) * units[character]
            number = 0
        else:
            section += number
            if units[character] == 100000000:
                total = (total + section) * units[character]
            else:
                total += section * units[character]
            section, number = 0, 0
    return str(total + section + number)


def normalize(text):
    text = unicodedata.normalize("NFKC", re.sub(r"<\|[^|]*\|>", "", text)).lower()
    text = re.sub("[零〇一二两三四五六七八九十百千万亿]+", chinese_number, text)
    return "".join(character for character in text if not character.isspace() and
                   unicodedata.category(character)[0] not in "PS")


def edit_distance(reference, hypothesis):
    previous = list(range(len(hypothesis) + 1))
    for row, expected in enumerate(reference, 1):
        current = [row]
        for column, actual in enumerate(hypothesis, 1):
            current.append(min(current[-1] + 1, previous[column] + 1,
                               previous[column - 1] + (expected != actual)))
        previous = current
    return previous[-1]


def compile_decoder(output):
    executable = output / "sensevoice_probe"
    subprocess.run(["xcrun", "clang", "-O2", "-Wall", "-Wextra", "-Werror",
                    str(ROOT / "scripts/rnnoise/sensevoice_probe.c"),
                    str(ROOT / "app/MemoEcho/Platform/SherpaOnnxBridge.c"),
                    "-o", str(executable)], check=True)
    return executable


def decode(args):
    output = args.output_dir.resolve()
    manifest = json.loads((output / "manifest.json").read_text())
    executable = compile_decoder(output)
    variants = {"raw": output / "input"}
    for spec in args.variant:
        name, path = spec.split("=", 1)
        if name == "raw" or name in variants:
            raise SystemExit(f"Duplicate variant: {name}")
        variants[name] = Path(path).resolve()
    cases = manifest["cases"][:args.limit] if args.limit else manifest["cases"]
    # Interleave variants, avoiding whole-variant drift in a longer decode run.
    jobs = [(case, variant, directory / f"{case['id']}.wav")
            for case in cases for variant, directory in variants.items()]
    for _, _, path in jobs:
        if not path.is_file():
            raise SystemExit(f"Missing processed input: {path}")
    commands = [str(executable), str(args.library.resolve()), str(args.model.resolve()),
                str(args.tokens.resolve())]
    tag = "smoke" if args.limit else "full"
    transcripts = output / f"transcripts-{tag}.jsonl"
    with transcripts.open("w") as log, (output / f"decoder-{tag}.log").open("w") as error_log:
        subprocess.run(commands, input="".join(str(path) + "\n" for _, _, path in jobs),
                       text=True, stdout=log, stderr=error_log, check=True)
    decoded = [json.loads(line) for line in transcripts.read_text().splitlines()]
    if len(decoded) != len(jobs):
        raise SystemExit("Decoder returned an incomplete result set")
    results = []
    for (case, variant, path), result in zip(jobs, decoded, strict=True):
        if result["path"] != str(path):
            raise SystemExit("Decoder path order mismatch")
        reference, hypothesis = normalize(case["reference"]), normalize(result["text"])
        edits = edit_distance(reference, hypothesis)
        results.append({"id": case["id"], "utterance_id": case["utterance_id"],
                        "voice": case["voice"], "category": case["category"],
                        "condition": case["condition"], "variant": variant,
                        "reference": case["reference"], "hypothesis": result["text"],
                        "reference_normalized": reference, "hypothesis_normalized": hypothesis,
                        "edits": edits, "reference_characters": len(reference),
                        "cer": edits / len(reference), "input_sha256": sha256(path),
                        "decode_seconds": result["decode_seconds"]})
    summary = []
    for condition in ["all", *(item[0] for item in CONDITIONS)]:
        for variant in variants:
            group = [result for result in results if result["variant"] == variant and
                     (condition == "all" or result["condition"] == condition)]
            if not group:
                continue
            characters = sum(result["reference_characters"] for result in group)
            errors = sum(result["edits"] for result in group)
            summary.append({"condition": condition, "variant": variant, "cases": len(group),
                            "reference_characters": characters, "edits": errors,
                            "cer": errors / characters})
    report = {"schema_version": 1, "normalization": NORMALIZATION,
              "recognizer": {"language": "zh", "use_itn": 1, "threads": 2,
                             "provider": "cpu", "decoding_method": "greedy_search",
                             "model_sha256": sha256(args.model),
                             "tokens_sha256": sha256(args.tokens),
                             "library_sha256": sha256(args.library)},
              "corpus_manifest_sha256": sha256(output / "manifest.json"),
              "scope": "Synthetic macOS Mandarin TTS + artificial noise only. No real-speech, cloud-ASR, or Intel acceptance.",
              "summary": summary, "results": results}
    write_json(output / f"results-{tag}.json", report)
    print(json.dumps({"report": str(output / f"results-{tag}.json"), "summary": summary},
                     ensure_ascii=False))


def analyze(output):
    """Re-score preserved transcripts without re-running ASR or changing references."""
    report = json.loads((output / "results-full.json").read_text())
    by_id = {}
    for result in report["results"]:
        by_id.setdefault(result["id"], {})[result["variant"]] = result
    comparisons = []
    for case_id, variants in by_id.items():
        baseline, candidate = variants["float"], variants["int8"]
        if baseline["reference_normalized"] != candidate["reference_normalized"]:
            raise ValueError(f"Reference mismatch: {case_id}")
        comparisons.append({
            "id": case_id, "condition": baseline["condition"],
            "reference": baseline["reference"],
            "float_hypothesis": baseline["hypothesis"],
            "int8_hypothesis": candidate["hypothesis"],
            "float_edits": baseline["edits"], "int8_edits": candidate["edits"],
            "edit_delta_int8_minus_float": candidate["edits"] - baseline["edits"],
            "normalized_transcript_identical": baseline["hypothesis_normalized"] == candidate["hypothesis_normalized"],
        })
    summary = []
    for condition in ["all", *(item[0] for item in CONDITIONS)]:
        group = [row for row in comparisons if condition == "all" or row["condition"] == condition]
        summary.append({
            "condition": condition, "cases": len(group),
            "int8_fewer_errors": sum(row["edit_delta_int8_minus_float"] < 0 for row in group),
            "int8_more_errors": sum(row["edit_delta_int8_minus_float"] > 0 for row in group),
            "equal_error_count": sum(row["edit_delta_int8_minus_float"] == 0 for row in group),
            "identical_normalized_transcript": sum(row["normalized_transcript_identical"] for row in group),
        })
    comparison = {
        "summary": summary,
        "largest_regressions": sorted((row for row in comparisons if row["edit_delta_int8_minus_float"] > 0),
                                      key=lambda row: (-row["edit_delta_int8_minus_float"], row["id"]))[:5],
        "largest_improvements": sorted((row for row in comparisons if row["edit_delta_int8_minus_float"] < 0),
                                       key=lambda row: (row["edit_delta_int8_minus_float"], row["id"]))[:5],
        "cases": comparisons,
    }
    write_json(output / "float-int8-comparison.json", comparison)
    manifest = json.loads((output / "manifest.json").read_text())
    waveforms = []
    for case in manifest["cases"]:
        decoded = {}
        row = {"id": case["id"], "condition": case["condition"], "samples": case["samples"]}
        for variant in ["input", "float", "int8"]:
            rate, samples = read_wav(output / variant / f"{case['id']}.wav")
            if rate != RATE or len(samples) != case["samples"] or not np.isfinite(samples).all():
                raise ValueError(f"Waveform format/length/finite-value check failed: {case['id']} {variant}")
            decoded[variant] = samples
            row[variant] = {"peak": float(np.abs(samples).max()),
                            "rms": float(np.sqrt(np.mean(samples * samples))),
                            "full_scale_samples": int(np.count_nonzero((samples <= -1) | (samples >= 32767 / 32768)))}
        delta = decoded["int8"] - decoded["float"]
        row["float_int8_rms_delta"] = float(np.sqrt(np.mean(delta * delta)))
        row["float_int8_peak_delta"] = float(np.max(np.abs(delta)))
        waveforms.append(row)
    write_json(output / "waveform-validation.json", {
        "checks": "216 WAVs: 16kHz mono PCM16, equal sample count per case, finite samples",
        "cases": waveforms,
    })
    print(json.dumps({"summary": summary, "largest_regressions": comparison["largest_regressions"]},
                     ensure_ascii=False))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["prepare", "decode", "compile", "analyze"])
    parser.add_argument("--output-dir", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--variant", action="append", default=[], help="NAME=directory of <case-id>.wav")
    parser.add_argument("--limit", type=int, help="Only first N cases (one clean sample for smoke)")
    parser.add_argument("--library", type=Path, default=ROOT / ".runtime/rnnoise/DerivedData/Build/Products/Debug/MemoEcho.app/Contents/Resources/sherpa-onnx/lib/libsherpa-onnx-c-api.dylib")
    parser.add_argument("--model", type=Path, default=Path.home() / ".memoecho/models/sensevoice-small-onnx/model.int8.onnx")
    parser.add_argument("--tokens", type=Path, default=Path.home() / ".memoecho/models/sensevoice-small-onnx/tokens.txt")
    args = parser.parse_args()
    args.output_dir.mkdir(parents=True, exist_ok=True)
    if args.command == "prepare":
        prepare(args.output_dir.resolve())
    elif args.command == "compile":
        print(compile_decoder(args.output_dir.resolve()))
    elif args.command == "analyze":
        analyze(args.output_dir.resolve())
    else:
        decode(args)


if __name__ == "__main__":
    main()
