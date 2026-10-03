#!/usr/bin/env bash
# Refuses to let a chart version be published twice.
#
# A chart version is a pin: whoever installs `--version X` must get the
# same templates every time. An OCI registry will happily overwrite a tag,
# so a second push under an existing version silently changes what that
# pin means. This asks the registry whether the tag already exists before
# publish runs, and refuses unless the answer is a clear "no".
#
# Usage: check-chart-version-unpublished.sh <oci-repo> <version>
#   e.g. check-chart-version-unpublished.sh ghcr.io/<owner>/openddil/charts/openddil-demo 0.1.73
#
# Optional: REGISTRY_USER + REGISTRY_TOKEN authenticate the token request
# (needed for a private package; a public one answers anonymously).
#
# Exit codes:
#   0  the version is not published; publishing it is safe
#   1  REFUSED: the version is already published; bump Chart.yaml's version
#   2  REFUSED: the registry gave no clear answer, so overwrite can't be ruled out
#
# Red check: run it against a version that is already published; it must
# exit 1.

set -uo pipefail

if [ $# -ne 2 ]; then
  echo "usage: $0 <oci-repo> <version>" >&2
  exit 2
fi

REPO_REF="$1"
VERSION="$2"
HOST="${REPO_REF%%/*}"
REPO="${REPO_REF#*/}"

auth=()
if [ -n "${REGISTRY_USER:-}" ] && [ -n "${REGISTRY_TOKEN:-}" ]; then
  auth=(-u "${REGISTRY_USER}:${REGISTRY_TOKEN}")
fi

token_json="$(curl -sS --max-time 30 "${auth[@]}" \
  "https://${HOST}/token?scope=repository:${REPO}:pull&service=${HOST}")" || {
  echo "REFUSED: could not reach https://${HOST}/token; cannot tell whether ${VERSION} is published" >&2
  exit 2
}
token="$(printf '%s' "$token_json" | sed -n 's/.*"token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
if [ -z "$token" ]; then
  echo "REFUSED: no registry token for ${REPO}; cannot tell whether ${VERSION} is published" >&2
  exit 2
fi

code="$(curl -sS --max-time 30 -o /dev/null -w '%{http_code}' -I \
  -H "Authorization: Bearer ${token}" \
  -H 'Accept: application/vnd.oci.image.manifest.v1+json' \
  "https://${HOST}/v2/${REPO}/manifests/${VERSION}")" || code="none"

case "$code" in
  404)
    echo "OK: ${REPO_REF}:${VERSION} is not published; safe to publish"
    exit 0
    ;;
  200)
    echo "REFUSED: ${REPO_REF}:${VERSION} is already published. A published version is never overwritten; bump version: in Chart.yaml." >&2
    exit 1
    ;;
  *)
    echo "REFUSED: registry answered HTTP ${code} for ${REPO_REF}:${VERSION}; cannot tell whether it is published" >&2
    exit 2
    ;;
esac
