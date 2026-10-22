#!/usr/bin/env bash
# Build the pinned RNNoise C core. Never import a plugin renamed as a dylib.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "${SCRIPT_DIR}/rnnoise/build.py" "$@"
