#!/usr/bin/env bash
# ===========================================================================
# test_reset_declared_unmeasured.sh -- offline proof for --declare-unmeasured
# in reset-scenario.sh, against the REAL verify_aggregator,
# write_exercise_reset_record and argument parser.
#
# Cases:
#   A. declared, no fresh row   -> DECLARED line, no FAIL, OVERALL_FAIL=0,
#                                  summary names it, record lists it.
#   B. not declared, no fresh   -> today's FAIL, OVERALL_FAIL=1, no record.
#   C. declared, fresh row 5    -> FAIL plus the "not used" note.
#   D. declared, fresh row 0    -> PASS, "not used" note, summary says none.
#   E. unknown name             -> rc 2, accepted names, no phase banner.
#   F. declared, no postgres pod-> FAIL.
# Guard flips are done by tests/flip runs against a mutated copy: set SCRIPT
# to the copy (see FLIPS in the header of the run notes).
# ===========================================================================
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${SCRIPT:-$HERE/../reset-scenario.sh}"

NS="openddil"
RELEASE="openddil"
export NS RELEASE

PY=""
for c in python python3 py; do
  if command -v "$c" >/dev/null 2>&1 && "$c" -c 'import json' >/dev/null 2>&1; then PY="$c"; break; fi
done
if [ -z "$PY" ]; then
  for c in /c/Users/*/AppData/Local/Programs/Python/Python3*/python.exe; do
    [ -x "$c" ] && PY="$c" && break
  done
fi

RESET_SCENARIO_SOURCE_ONLY=1
export RESET_SCENARIO_SOURCE_ONLY
set --
# shellcheck source=../reset-scenario.sh
. "$SCRIPT"
set +e

FAIL=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAIL=1; }

APPLY_LOG="$(mktemp)"
trap 'rm -f "$APPLY_LOG"' EXIT

# --- stubs: the aggregator check reads one table through pg_query -----------
FRESH_ROWS=0
MAX_COUNT=0
pg_query() {
  case "$2" in
    "SELECT count(*)"*) echo "$FRESH_ROWS" ;;
    "SELECT coalesce(max(asset_count)"*) echo "$MAX_COUNT" ;;
    *) echo "" ;;
  esac
}
sleep() { :; }
AGGREGATOR_POLL_TIMEOUT_SECONDS=1
AGGREGATOR_POLL_INTERVAL_SECONDS=1
RUN_STARTED_AT="2026-01-01T00:00:00Z"

kubectl() {
  case "$*" in
    "get deploy -n $NS ${RELEASE}-exercise-control -o name")
      echo "deployment.apps/${RELEASE}-exercise-control"; return 0 ;;
    "create configmap ${RELEASE}-exercise-reset-record -n $NS"*"--dry-run=client -o yaml")
      local a lit=""
      for a in "$@"; do
        case "$a" in --from-literal=record.json=*) lit="${a#--from-literal=record.json=}" ;; esac
      done
      printf 'data:\n  record.json: %s\n' "$lit"; return 0 ;;
    "apply -f -") cat >> "$APPLY_LOG"; return 0 ;;
    *) return 0 ;;
  esac
}

# run_case DECLARED(true|false) FRESH MAX PODS(true|false) -> sets out, OVERALL_FAIL
run_case() {
  DECLARED_UNMEASURED=(); DECLARED_UNMEASURED_USED=()
  $1 && DECLARED_UNMEASURED=(aggregator-region-fleet-summary)
  FRESH_ROWS="$2"; MAX_COUNT="$3"
  if $4; then POSTGRES_PODS=("openddil-postgres-region-east-0"); else POSTGRES_PODS=(); fi
  OVERALL_FAIL=0
  : > "$APPLY_LOG"
  out="$(verify_aggregator 2>&1; echo "OF=$OVERALL_FAIL"; echo "USED=${DECLARED_UNMEASURED_USED[*]-}")"
  # verify_aggregator ran in a subshell above; recover its state from the echoes
  OF="$(printf '%s\n' "$out" | sed -n 's/^OF=//p')"
  USED="$(printf '%s\n' "$out" | sed -n 's/^USED=//p')"
  DECLARED_UNMEASURED_USED=(); [ -n "$USED" ] && DECLARED_UNMEASURED_USED=($USED)
}

# --- A ----------------------------------------------------------------------
run_case true 0 0 true
summary="$(print_declared_unmeasured_summary)"
write_exercise_reset_record >/dev/null 2>&1
rec="$(sed -n 's/^  record.json: //p' "$APPLY_LOG")"
if echo "$out" | grep -q -- '-> DECLARED UNMEASURED (not a pass)' \
   && echo "$out" | grep -q 'declared by --declare-unmeasured aggregator-region-fleet-summary' \
   && ! echo "$out" | grep -q -- 'ACTUAL=UNMEASURED  -> FAIL' \
   && [ "$OF" = 0 ] \
   && [ "$summary" = "Declared unmeasured (not passes): aggregator-region-fleet-summary" ] \
   && [ -n "$PY" ] \
   && printf '%s' "$rec" | "$PY" -c 'import json,sys; d=json.loads(sys.stdin.read()); assert d["declared_unmeasured"]==["aggregator-region-fleet-summary"] and d["verdict"]=="PASS"'; then
  pass "A: declared + no fresh row -> DECLARED line, OVERALL_FAIL=0, summary and record name it"
else
  fail "A: declared + no fresh row (OF=$OF summary=[$summary] rec=[$rec]) :: $out"
fi

# --- B ----------------------------------------------------------------------
run_case false 0 0 true
if echo "$out" | grep -q -- 'ACTUAL=UNMEASURED  -> FAIL' && [ "$OF" = 1 ] \
   && ! echo "$out" | grep -q 'DECLARED UNMEASURED' && [ ! -s "$APPLY_LOG" ]; then
  pass "B: not declared + no fresh row -> FAIL, OVERALL_FAIL=1, no record"
else
  fail "B: not declared (OF=$OF) :: $out"
fi

# --- C ----------------------------------------------------------------------
run_case true 3 5 true
if echo "$out" | grep -Eq 'asset_count \(max over fresh rows\) +predicted=0 +actual=5 +FAIL' \
   && [ "$OF" = 1 ] \
   && echo "$out" | grep -q 'was declared unmeasured but was measured; the declaration was not used'; then
  pass "C: declared + fresh row 5 -> FAIL plus not-used note"
else
  fail "C: declared + fresh 5 (OF=$OF) :: $out"
fi

# --- D ----------------------------------------------------------------------
run_case true 3 0 true
summary="$(print_declared_unmeasured_summary)"
if echo "$out" | grep -Eq 'actual=0 +PASS' && [ "$OF" = 0 ] \
   && echo "$out" | grep -q 'was declared unmeasured but was measured; the declaration was not used' \
   && [ "$summary" = "Declared unmeasured (not passes): none" ]; then
  pass "D: declared + fresh row 0 -> PASS, not-used note, summary none"
else
  fail "D: declared + fresh 0 (OF=$OF summary=[$summary]) :: $out"
fi

# --- E (real argument parser, subprocess, source-only: no cluster) ----------
eout="$(RESET_SCENARIO_SOURCE_ONLY=1 bash "$SCRIPT" --declare-unmeasured bogus 2>&1)"
erc=$?
if [ "$erc" -eq 2 ] && echo "$eout" | grep -q 'aggregator-region-fleet-summary' \
   && ! echo "$eout" | grep -Eq '=== PHASE|reset-scenario: namespace='; then
  pass "E: unknown name -> rc 2, accepted names listed, no phase banner"
else
  fail "E: unknown name (rc=$erc) :: $eout"
fi

# --- F ----------------------------------------------------------------------
run_case true 0 0 false
if echo "$out" | grep -q 'no region-east or hq postgres pod discovered' && [ "$OF" = 1 ]; then
  pass "F: declared + no postgres pod -> FAIL"
else
  fail "F: declared + no pod (OF=$OF) :: $out"
fi

echo
if [ "$FAIL" -eq 0 ]; then
  echo "test_reset_declared_unmeasured: ALL PASS"
  exit 0
fi
echo "test_reset_declared_unmeasured: FAILED"
exit 1
