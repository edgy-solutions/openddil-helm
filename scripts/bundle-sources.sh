#!/usr/bin/env bash
# Read and validate bundle-sources.lock. Usage: bundle-sources.sh [lockfile]
# Refuses (exit 1) unless contracts, stack, tactical-agents and demo each appear
# exactly once with a 40-lowercase-hex commit and no other non-comment line
# exists. On success prints "<repo>=<sha>" lines (the form GITHUB_OUTPUT takes).
set -u
LOCK="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/bundle-sources.lock}"
[ -f "$LOCK" ] || { echo "bundle-sources: $LOCK not found" >&2; exit 1; }

rc=0
declare -A seen
while IFS= read -r line || [ -n "$line" ]; do
  line="${line%$'\r'}"
  case "$line" in ''|'#'*) continue ;; esac
  if [[ "$line" =~ ^(contracts|stack|tactical-agents|demo)\ ([0-9a-f]{40})$ ]]; then
    repo="${BASH_REMATCH[1]}"
    if [ -n "${seen[$repo]:-}" ]; then
      echo "bundle-sources: $repo appears more than once" >&2; rc=1
    fi
    seen[$repo]="${BASH_REMATCH[2]}"
  else
    echo "bundle-sources: refused line: $line" >&2; rc=1
  fi
done < "$LOCK"

for repo in contracts stack tactical-agents demo; do
  [ -n "${seen[$repo]:-}" ] || { echo "bundle-sources: $repo is missing" >&2; rc=1; }
done
[ "$rc" = 0 ] || exit 1
for repo in contracts stack tactical-agents demo; do
  echo "$repo=${seen[$repo]}"
done
