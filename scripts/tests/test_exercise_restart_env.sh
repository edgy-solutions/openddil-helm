#!/usr/bin/env bash
# ===========================================================================
# test_exercise_restart_env.sh -- offline render proof that
# exerciseControl.restartMaxZeroAgeSeconds reaches exercise-control as
# EXERCISE_RESTART_MAX_ZERO_AGE_S (default 1800, and an override).
# ===========================================================================
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART="${CHART:-$HERE/../../openddil-demo}"
FAIL=0
render() {
  helm template t "$CHART" --set releasability.enabled=true --set exerciseControl.enabled=true \
    --set exerciseControl.adapter.name=x \
    --set exerciseControl.adapter.endpoint=https://example.invalid/api \
    --set exerciseControl.adapter.operations.pause.method=POST \
    --set exerciseControl.adapter.operations.pause.path=/pause "$@" 2>&1 | tr -d '\r'
}
want() {  # $1 = case, $2 = rendered text, $3 = expected value
  if printf '%s\n' "$2" | grep -A1 'name: EXERCISE_RESTART_MAX_ZERO_AGE_S' | grep -q "value: \"$3\""; then
    echo "PASS $1"; else echo "FAIL $1: want EXERCISE_RESTART_MAX_ZERO_AGE_S=$3"; FAIL=1; fi
}
want "default 1800" "$(render)" 1800
want "override 600" "$(render --set exerciseControl.restartMaxZeroAgeSeconds=600)" 600
exit "$FAIL"
