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

# ----- Post-bake validation ------------------------------------------------
# Before we publish anything, extract the schema migrations from the freshly
# built image and run `atlas migrate validate` against them. This catches the
# class of failure where a migration was added to openddil-stack but the
# author forgot to regenerate atlas.sum -- the bundle would otherwise ship
# with a stale checksum and crash postgres-schema-init in a loop at every
# downstream cluster (see ADR notes / 2026-06-03 incident).
#
# We validate the BAKED image, not the source, so even if the Dockerfile
# evolves to do anything non-trivial during COPY, the integrity check still
# reflects what consumers will actually see.
echo "==> Validating atlas migrations in built image (pre-publish gate)"
TMP_MIG=$(mktemp -d)
trap 'rm -rf "$TMP_MIG"' EXIT

# Stream the migrations dir out of the image into a temp dir on host.
# `docker run` with tar over stdout is the most portable way -- avoids
# `docker cp` quirks across Docker Desktop versions.
docker run --rm --entrypoint sh "${IMAGE}:${VERSION}" \
  -c 'cd /bundle/stack/schema/migrations && tar c .' \
  | tar x -C "$TMP_MIG"

# Run atlas validate. Mount the extracted migrations read-only.
# MSYS_NO_PATHCONV protects the volume path against Git Bash on Windows
# mangling /migrations to C:/Program Files/Git/migrations.
if ! MSYS_NO_PATHCONV=1 docker run --rm \
    -v "${TMP_MIG}:/migrations:ro" \
    arigaio/atlas:0.32.0 \
    migrate validate --dir 'file:///migrations'; then
  echo ""                                                                    >&2
  echo "ERROR: atlas migrate validate FAILED on the freshly-built bundle."   >&2
  echo "       atlas.sum is out of sync with the migration files in"         >&2
  echo "       openddil-stack/schema/migrations/."                            >&2
  echo ""                                                                    >&2
  echo "       Likely cause: someone added or modified a migration file"     >&2
  echo "       without re-running 'atlas migrate hash'. To fix:"             >&2
  echo ""                                                                    >&2
  echo "         cd openddil-stack/schema"                                   >&2
  echo "         docker run --rm \\"                                          >&2
  echo "           -v \"\$(pwd)/migrations:/migrations\" \\"                    >&2
  echo "           arigaio/atlas:0.32.0 \\"                                   >&2
  echo "           migrate hash --dir 'file:///migrations'"                    >&2
  echo "         git add migrations/atlas.sum"                                >&2
  echo "         git commit -m 'atlas: regenerate sum after migration change'" >&2
  echo "         git push"                                                   >&2
  echo ""                                                                    >&2
  echo "       Then re-run build-bundle.sh. The bundle that was just built"  >&2
  echo "       is NOT being published."                                       >&2
  echo ""                                                                    >&2
  exit 1
fi
echo "==> Atlas validation passed: $(ls "$TMP_MIG"/*.sql | wc -l) migrations + atlas.sum in sync"
rm -rf "$TMP_MIG"
trap - EXIT

echo "Pushing ${IMAGE}:${VERSION} and ${IMAGE}:latest"
docker push "${IMAGE}:${VERSION}"
docker push "${IMAGE}:latest"

echo
echo "Built: ${IMAGE}:${VERSION}"
echo "Update Helm values.yaml -> bundle.image.tag if pinning a specific version."
