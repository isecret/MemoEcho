#!/usr/bin/env python3
"""Optimize the offline preview into a small, cacheable Cloudflare Pages site."""
import base64
import hashlib
import io
import json
from pathlib import Path
import re
import shutil

from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "dist/website"
ICONS = ("favicon.ico", "favicon-16x16.png", "favicon-32x32.png",
         "apple-touch-icon.png", "icon-192.png", "icon-512.png")
allowed = {"index.html", "404.html", "favicon.ico", "_headers"} | {f"site-icons/{name}" for name in ICONS}
if OUTPUT.exists():
    unexpected = {str(p.relative_to(OUTPUT)) for p in OUTPUT.rglob("*") if p.is_file()} - allowed
    unexpected = {name for name in unexpected
                  if not re.fullmatch(r"assets/[a-z-]+\.[0-9a-f]{16}\.webp", name)}
    if unexpected:
        raise SystemExit(f"Unexpected files in publish directory: {sorted(unexpected)}")

(OUTPUT / "site-icons").mkdir(parents=True, exist_ok=True)
source = (ROOT / "docs/website-preview.html").read_text()
# Design provenance stays in the source; ship only the page itself.
source = re.sub(r"<!--.*?-->", "", source, flags=re.DOTALL)
assets = {}


def image_asset(data_uri, name, *, size=None, lossless=False):
    image = Image.open(io.BytesIO(base64.b64decode(data_uri.split(",", 1)[1])))
    image = image.convert("RGBA" if "A" in image.getbands() else "RGB")
    if size:
        image.thumbnail(size, Image.Resampling.LANCZOS)
    encoded = io.BytesIO()
    # Keep the ship and logo lossless; retain full resolution for the terrain.
    image.save(encoded, "WEBP", quality=88, method=6, lossless=lossless)
    payload = encoded.getvalue()
    digest = hashlib.sha256(payload).hexdigest()[:16]
    path = f"assets/{name}.{digest}.webp"
    assets[path] = payload
    return path


def external_image(match):
    tag = match.group(0)
    embedded = re.search(r'data:image/[^;]+;base64,[A-Za-z0-9+/=]+', tag)
    if not embedded:
        return tag
    name = re.search(r'class="([a-z-]+)"', tag)[1]
    # The animation samples six 64px sprites from this atlas.
    size = (384, 256) if name == "rock-atlas" else None
    path = image_asset(embedded[0], name, size=size, lossless=name in {"craft", "brand-logo"})
    tag = tag.replace(embedded[0], path)
    tag = re.sub(r' fetchpriority="[^"]+"', '', tag)
    priority = "high" if name in {"craft", "art", "rock-atlas"} else "auto"
    return tag.replace("<img ", f'<img decoding="async" fetchpriority="{priority}" ', 1)


source = re.sub(r'<img\b[^>]*>', external_image, source)
# Discover the scene images before the body, with the UFO first.
preloads = []
for name in ("craft", "art", "rock-atlas"):
    path = next(path for path in assets if path.startswith(f"assets/{name}."))
    preloads.append(f'  <link rel="preload" as="image" href="{path}" fetchpriority="high">')
source = source.replace("</head>", "\n".join(preloads) + "\n</head>", 1)
demo_pattern = r'(<script id="onboarding-demo-data" type="application/json">)(.*?)(</script>)'
demo = re.search(demo_pattern, source, re.DOTALL)
data = json.loads(demo[2])
data["avatar"] = image_asset(data["avatar"], "demo-avatar", size=(96, 96))
source = source[:demo.start(2)] + json.dumps(data, ensure_ascii=False) + source[demo.end(2):]

(OUTPUT / "assets").mkdir(exist_ok=True)
for name, payload in assets.items():
    (OUTPUT / name).write_bytes(payload)
# Remove only generated, fingerprinted assets from previous builds.
for path in (OUTPUT / "assets").glob("*.webp"):
    if str(path.relative_to(OUTPUT)) not in assets:
        path.unlink()
(OUTPUT / "_headers").write_text("/assets/*\n  Cache-Control: public, max-age=31536000, immutable\n")
(OUTPUT / "index.html").write_text(source)
for name in ICONS:
    shutil.copyfile(ROOT / "docs/site-icons" / name, OUTPUT / "site-icons" / name)
shutil.copyfile(OUTPUT / "site-icons/favicon.ico", OUTPUT / "favicon.ico")
(OUTPUT / "404.html").write_text('''<!doctype html>
<html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>页面不存在 · MemoEcho</title><link rel="icon" href="/favicon.ico">
<body style="margin:0;min-height:100vh;display:grid;place-content:center;background:#030303;color:#eee;font-family:system-ui;text-align:center">
<h1>页面不存在</h1><p><a href="/" style="color:inherit">返回 MemoEcho 首页</a></p></body></html>
''')
for path in OUTPUT.rglob("*"):
    if path.is_file() and path.stat().st_size > 25 * 1024 * 1024:
        raise SystemExit(f"File exceeds Pages upload limit: {path.name}")
files = [p for p in OUTPUT.rglob("*") if p.is_file()]
print(f"Built {len(files)} files in {OUTPUT.relative_to(ROOT)}: "
      f"HTML {len(source.encode()):,} bytes, total {sum(p.stat().st_size for p in files):,} bytes")
