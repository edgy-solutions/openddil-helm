#!/usr/bin/env bash
# Build + push the openddil runtime bundle image.
#
# Usage:
#   cd <parent-of-openddil-*-repos>
#   ./openddil-helm/scripts/build-bundle.sh [VERSION]
#
# VERSION defaults to a date-based tag (vYYYYMMDD-<git-short-sha>). The
# image is also tagged :latest.
set -euo pipefail

REGISTRY="${OPENDDIL_REGISTRY:-ghcr.io/edgy-solutions/openddil}"
IMAGE="${REGISTRY}/runtime-bundle"

# Derive version
if [[ $# -ge 1 ]]; then
  VERSION="$1"
else
  SHA="$(git -C openddil-demo rev-parse --short HEAD 2>/dev/null || echo nogit)"
  VERSION="v$(date -u +%Y%m%d)-${SHA}"
fi

# Sanity: confirm we're in the parent directory
for repo in openddil-contracts openddil-stack openddil-tactical-agents openddil-demo; do
  if [[ ! -d "${repo}" ]]; then
    echo "ERROR: ./${repo} not found. Run this script from the parent directory" >&2
    echo "       containing all four openddil-* repos (cwd: $(pwd))" >&2
    exit 1
  fi
done

echo "Building ${IMAGE}:${VERSION} (and :latest)"
docker build \
  -f openddil-helm/bundle/Dockerfile \
  -t "${IMAGE}:${VERSION}" \
  -t "${IMAGE}:latest" \
  .

echo "Pushing ${IMAGE}:${VERSION} and ${IMAGE}:latest"
docker push "${IMAGE}:${VERSION}"
docker push "${IMAGE}:latest"

echo
echo "Built: ${IMAGE}:${VERSION}"
echo "Update Helm values.yaml -> bundle.image.tag if pinning a specific version."
