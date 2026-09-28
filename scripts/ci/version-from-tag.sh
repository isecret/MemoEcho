#!/usr/bin/env bash

set -euo pipefail

usage() {
    cat <<'EOF'
Usage:
  ./scripts/ci/version-from-tag.sh [--build-version] <vX.Y.Z[-beta.N]>
  ./scripts/ci/version-from-tag.sh [--build-version] --tag <vX.Y.Z[-beta.N]>

Parse an explicitly supplied release tag. Local builds use app/project.yml.
EOF
}

if [[ $# -eq 1 && ( "$1" == "--help" || "$1" == "-h" ) ]]; then
    usage
    exit 0
fi

BUILD_VERSION=0
if [[ "${1:-}" == "--build-version" ]]; then
    BUILD_VERSION=1
    shift
fi

if [[ $# -eq 2 && "$1" == "--tag" ]]; then
    TAG="$2"
elif [[ $# -eq 1 ]]; then
    TAG="$1"
else
    usage >&2
    exit 1
fi

if [[ "${TAG}" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-beta\.([1-9][0-9]{0,2}))?$ ]]; then
    BETA_NUMBER="${BASH_REMATCH[5]:-}"
    if [[ -n "$BETA_NUMBER" && "$BETA_NUMBER" -gt 255 ]]; then
        echo "error: beta number must be between 1 and 255" >&2
        exit 1
    fi
    VERSION="${TAG#v}"
    if [[ "$BUILD_VERSION" == "1" && -n "$BETA_NUMBER" ]]; then
        echo "${VERSION%-beta.*}b${BETA_NUMBER}"
    else
        echo "$VERSION"
    fi
else
    echo "error: expected tag in format vX.Y.Z or vX.Y.Z-beta.N (N: 1–255), got '${TAG}'" >&2
    exit 1
fi
