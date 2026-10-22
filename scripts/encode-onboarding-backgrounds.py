#!/usr/bin/env python3
"""Encode opaque onboarding PNG masters as JPEG assets without resizing/redrawing."""
import json
from pathlib import Path
import subprocess


ROOT = Path(__file__).resolve().parents[1]
MASTERS = ROOT / "assets/onboarding-backgrounds"
ASSETS = ROOT / "app/MemoEcho/Resources/Assets.xcassets"
NAMES = ("OnboardingDemoBackground", "OnboardingModelBackground",
         "OnboardingHotkeyBackground", "OnboardingTrialBackground")


def main():
    # Preserve native pixel dimensions and the existing SwiftUI crop. Quality 95
    # retains the subtle paper texture while removing PNG's large payload.
    for name in NAMES:
        source = MASTERS / f"{name}.png"
        directory = ASSETS / f"{name}.imageset"
        contents = directory / "Contents.json"
        data = json.loads(contents.read_text())
        destination = directory / "background.jpg"
        subprocess.run(["sips", "-s", "format", "jpeg", "-s", "formatOptions", "95",
                        str(source), "--out", str(destination)], check=True, capture_output=True)
        data["images"][0]["filename"] = destination.name
        contents.write_text(json.dumps(data, indent=2) + "\n")
        print(f"{name}: {source.stat().st_size:,} -> {destination.stat().st_size:,} bytes")


if __name__ == "__main__":
    main()
