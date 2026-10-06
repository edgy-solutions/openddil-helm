#!/usr/bin/env bash
# =============================================================================
# check-image-pins.sh — every image a deployment runs is pinned by digest
# =============================================================================
#
# WHY THIS EXISTS
# ---------------
# A tag is a pointer that moves. With pullPolicy Always, a service whose
# image is `:latest` changes code on any pod restart — a node drain, an
# eviction, a crash — and no release records it. The chart already makes
# every image PINNABLE (check-mirror-coverage.sh, pass 2). This check asks
# the other question: does THIS deployment's values chain actually pin
# every one of them?
#
# It renders the chart with the deployment's own values files, in the
# deployment's order, and reads every `image:` the render produces —
# workloads, init containers and hook Jobs alike. A reference without
# `@sha256:<64 hex>` fails, by name.
#
# USAGE
#   scripts/check-image-pins.sh <chart-dir> [helm template args...]
#   e.g. scripts/check-image-pins.sh ./openddil-demo -n openddil \
#          -f base.yaml -f site.yaml
#
# EXIT
#   0  every rendered image is digest-pinned (the count is printed)
#   1  at least one image is not; each is listed
#   3  NOT RUN: the render failed, or produced no images. Zero images is
#      not "all pinned"; it is a render that measured nothing.
# =============================================================================
set -uo pipefail

if [ $# -lt 1 ] || [ ! -d "$1" ]; then
  echo "usage: $0 <chart-dir> [helm template args...]" >&2
  exit 3
fi
chart="$1"; shift

render="$(mktemp)"; errs="$(mktemp)"
trap 'rm -f "$render" "$errs"' EXIT

if ! helm template image-pin-check "$chart" "$@" >"$render" 2>"$errs"; then
  echo "NOT RUN: helm template failed:" >&2
  tail -5 "$errs" >&2
  exit 3
fi

# An `image:` key with no value is a render defect, not an absent image; it
# is listed as <empty> so it fails instead of dropping out of the count.
images="$(sed -nE 's/^[[:space:]]*(-[[:space:]]+)?image:[[:space:]]*"?([^"[:space:]]*)"?[[:space:]]*$/\2/p' "$render" \
  | sed 's/^$/<empty>/' | sort -u)"
total="$(printf '%s\n' "$images" | grep -c .)"
if [ "$total" -eq 0 ]; then
  echo "NOT RUN: the render produced no image references." >&2
  exit 3
fi

unpinned="$(printf '%s\n' "$images" | grep -vE '@sha256:[0-9a-f]{64}$' || true)"
if [ -n "$unpinned" ]; then
  n="$(printf '%s\n' "$unpinned" | grep -c .)"
  echo "FAIL: $n of $total rendered image(s) are not pinned by digest:"
  printf '%s\n' "$unpinned" | sed 's/^/    /'
  exit 1
fi

echo "OK: $total rendered image(s), all pinned by digest."
