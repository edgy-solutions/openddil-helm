#!/usr/bin/env bash
# Package + push the openddil-demo chart as an OCI artifact to ghcr.io.
#
# Usage:
#   cd <parent-of-openddil-*-repos>
#   ./openddil-helm/scripts/publish-chart.sh
#
# Reads version from Chart.yaml. Requires `helm` (3.8+) and `docker login
# ghcr.io` (or `gh auth token | helm registry login ghcr.io -u USER --password-stdin`).
set -euo pipefail

REGISTRY="${OPENDDIL_CHART_REGISTRY:-oci://ghcr.io/edgy-solutions/openddil/charts}"
CHART_DIR="openddil-helm/openddil-demo"

if [[ ! -f "${CHART_DIR}/Chart.yaml" ]]; then
  echo "ERROR: ${CHART_DIR}/Chart.yaml not found. Run from the parent" >&2
  echo "       directory containing openddil-helm/" >&2
  exit 1
fi

VERSION="$(awk '/^version:/ {print $2; exit}' "${CHART_DIR}/Chart.yaml")"

echo "Linting ${CHART_DIR}"
helm lint "${CHART_DIR}"

echo "Packaging ${CHART_DIR} -> openddil-demo-${VERSION}.tgz"
helm package "${CHART_DIR}" -d /tmp

echo "Pushing /tmp/openddil-demo-${VERSION}.tgz to ${REGISTRY}"
helm push "/tmp/openddil-demo-${VERSION}.tgz" "${REGISTRY}"

echo
echo "Published: ${REGISTRY}/openddil-demo:${VERSION}"
echo "Install:   helm install openddil ${REGISTRY}/openddil-demo --version ${VERSION}"
