#!/usr/bin/env bash
# ===========================================================================
# check-algorithm-declarations.sh [TA_DIR]
#
# The chart validates algorithm overrides against its OWN copy of each unit
# declaration (openddil-demo/files/algorithms/<unit>/unit.yaml). The pod runs
# the copy that ships in the bundle (openddil-tactical-agents/algorithms/
# <unit>/unit.yaml, ruling D1). This check is what keeps the two the same
# file: a byte compare, per unit the chart carries.
#
#   TA_DIR  openddil-tactical-agents checkout (default ../openddil-tactical-agents
#           beside this repo)
#
# Exit 0: every chart copy is identical to its source.
# Exit 1: a copy differs or its source is missing (one line per unit).
# Exit 2: TA_DIR absent (prints SKIP). Never a pass.
# ===========================================================================
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART_FILES="${CHART_FILES:-$HERE/../openddil-demo/files/algorithms}"
TA_DIR="${1:-$HERE/../../openddil-tactical-agents}"

if [ ! -d "$TA_DIR" ]; then
  echo "SKIP: $TA_DIR absent"
  exit 2
fi

rc=0
n=0
for f in "$CHART_FILES"/*/unit.yaml; do
  [ -e "$f" ] || continue
  unit="$(basename "$(dirname "$f")")"
  src="$TA_DIR/algorithms/$unit/unit.yaml"
  n=$((n + 1))
  if [ ! -f "$src" ]; then
    echo "MISSING: unit $unit: chart copy $f has no source at $src"
    rc=1
  elif ! cmp -s "$f" "$src"; then
    echo "DIFFERS: unit $unit: chart copy $f != $src"
    rc=1
  fi
done

if [ "$n" -eq 0 ]; then
  echo "FAIL: no chart copies under $CHART_FILES"
  exit 1
fi
[ "$rc" -eq 0 ] && echo "ok: $n chart copy(ies) match $TA_DIR"
exit "$rc"
