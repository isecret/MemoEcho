#!/usr/bin/env python3
"""Export website icons from approved branding assets (macOS sips required)."""
from pathlib import Path
import shutil
import struct
import subprocess

ROOT = Path(__file__).resolve().parents[1]
DESTINATION = ROOT / "docs/site-icons"
APP_ICONS = ROOT / "app/MemoEcho/Resources/Assets.xcassets/AppIcon.appiconset"
DESTINATION.mkdir(parents=True, exist_ok=True)

for size in (16, 32):
    shutil.copyfile(APP_ICONS / f"app_icon_{size}x{size}@1x.png",
                    DESTINATION / f"favicon-{size}x{size}.png")

for name, size in (("apple-touch-icon.png", 180), ("icon-192.png", 192), ("icon-512.png", 512)):
    subprocess.run(["sips", "-z", str(size), str(size),
                    str(ROOT / "assets/branding/app-icon-master.png"),
                    "--out", str(DESTINATION / name)], check=True, stdout=subprocess.DEVNULL)

# ICO supports PNG frames; reuse the exported pixels without recompressing them.
frames = [(size, (DESTINATION / f"favicon-{size}x{size}.png").read_bytes()) for size in (16, 32)]
offset = 6 + 16 * len(frames)
directory = bytearray(struct.pack("<HHH", 0, 1, len(frames)))
for size, payload in frames:
    directory.extend(struct.pack("<BBBBHHII", size, size, 0, 0, 1, 32, len(payload), offset))
    offset += len(payload)
(DESTINATION / "favicon.ico").write_bytes(directory + b"".join(payload for _, payload in frames))
print(f"Exported website icons to {DESTINATION.relative_to(ROOT)}")
