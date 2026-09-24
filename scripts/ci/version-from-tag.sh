#!/usr/bin/env bash

set -euo pipefail

usage() {
    cat <<'EOF'
Usage:
  ./scripts/ci/version-from-tag.sh <vX.Y.Z>
  ./scripts/ci/version-from-tag.sh --tag <vX.Y.Z>

Parse an explicitly supplied release tag. Local builds use app/project.yml.
EOF
}

if [[ $# -eq 1 && ( "$1" == "--help" || "$1" == "-h" ) ]]; then
    usage
    exit 0
fi

if [[ $# -eq 2 && "$1" == "--tag" ]]; then
    TAG="$2"
elif [[ $# -eq 1 ]]; then
    TAG="$1"
else
    usage >&2
    exit 1
fi

if [[ "${TAG}" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
    echo "${TAG#v}"
else
    echo "error: expected release tag in format vX.Y.Z, got '${TAG}'" >&2
    exit 1
fi
