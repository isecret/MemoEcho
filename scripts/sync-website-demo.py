#!/usr/bin/env python3
"""Embed approved onboarding demo copy, timing and avatar into the offline website."""
import base64
import json
from pathlib import Path
import re

root = Path(__file__).resolve().parent.parent
source = (root / "app/MemoEcho/UI/Onboarding/OnboardingWelcomeDemo.swift").read_text()
data = {key: re.search(rf'static let {key} = "([^"]+)"', source).group(1)
        for key in ("question", "originalText", "reply")}
data["deletedOriginalPhrases"] = json.loads(re.search(r'static let deletedOriginalPhrases = (\[[^\n]+\])', source).group(1))
data["retainedCorrection"] = re.search(r'static var highlightedReply:[\s\S]*?range\(of: "([^"]+)"', source).group(1)
data["duration"] = float(re.search(r'truncatingRemainder\(dividingBy: ([\d.]+)\)', source).group(1))
data["phases"] = [{"until": float(end), "name": phase} for end, phase in
                  re.findall(r'case \.\.<([\d.]+): return \.(\w+)', source)]
data["phases"].append({"until": data["duration"], "name": "filled"})
avatar = root / "app/MemoEcho/Resources/Assets.xcassets/OnboardingAvatar.imageset/avatar.jpeg"
data["avatar"] = "data:image/jpeg;base64," + base64.b64encode(avatar.read_bytes()).decode()
page = root / "docs/website-preview.html"
html, count = re.subn(r'(<script id="onboarding-demo-data" type="application/json">).*?(</script>)',
                     lambda match: match[1] + json.dumps(data, ensure_ascii=False).replace("<", "\\u003c") + match[2],
                     page.read_text(), flags=re.S)
if count != 1:
    raise SystemExit("Expected one onboarding-demo-data block; HTML was not changed.")
page.write_text(html)
print("Synced onboarding demo copy, five phases and avatar.")
