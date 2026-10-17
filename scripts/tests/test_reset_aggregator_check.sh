#!/usr/bin/env bash
# ===========================================================================
# test_reset_aggregator_check.sh -- offline proof for the regional rollup check
# in reset-scenario.sh, against the REAL verify_aggregator and argument parser.
#
# Cases:
#   A. table 0, topic empty, sweep-tick advances -> 3+ PASS, OVERALL_FAIL=0.
#   B. sweep-tick never advances                 -> alive FAIL, OVERALL_FAIL=1.
#   C. table holds 1 row                         -> FAIL.
#   D. topic log_start < hw                      -> FAIL.
#   E. no postgres pod                           -> FAIL.
#   F. no sweep-tick topic on any broker         -> UNMEASURED, OVERALL_FAIL=1.
#   G. --declare-unmeasured aggregator-region-fleet-summary -> rc 2, retired
#      message, no phase banner.
#   H. --declare-unmeasured foo                  -> rc 2.
# Guard flips are done against a mutated copy: set SCRIPT to the copy.
# ===========================================================================
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${SCRIPT:-$HERE/../reset-scenario.sh}"

NS="openddil"
RELEASE="openddil"
export NS RELEASE

RESET_SCENARIO_SOURCE_ONLY=1
export RESET_SCENARIO_SOURCE_ONLY
set --
# shellcheck source=../reset-scenario.sh
. "$SCRIPT"
set +e

FAIL=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAIL=1; }

# --- stubs ------------------------------------------------------------------
TABLE_ROWS=0
TOPIC_LOGSTART=5      # region-fleet-summary log_start; hw is fixed at 5
SWEEP_STEP=1          # sweep-tick hw advance per read
HAVE_SWEEP=true
pg_query() { echo "$TABLE_ROWS"; }
sleep() { :; }
broker_topics() {
  echo "region-fleet-summary"
  $HAVE_SWEEP && echo "openddil-aggregator-sweep-tick"
  echo "other-topic"
}
# topic_partitions advances the sweep-tick hw, and it runs inside $(...) in the helper,
# so the counter is kept in a file instead of a variable.
SWEEP_FILE="$(mktemp)"
trap 'rm -f "$SWEEP_FILE"' EXIT
topic_partitions() {
  local n
  case "$2" in
    region-fleet-summary) echo "0 $TOPIC_LOGSTART 5" ;;
    *-aggregator-sweep-tick)
      n="$(cat "$SWEEP_FILE")"; echo "0 0 $n"; echo $((n + SWEEP_STEP)) > "$SWEEP_FILE" ;;
    *) echo "0 1 9" ;;
  esac
}
AGGREGATOR_POLL_TIMEOUT_SECONDS=3
AGGREGATOR_POLL_INTERVAL_SECONDS=1
REDPANDA_PODS=("openddil-redpanda-region-east-0")

# run_case ROWS LOGSTART STEP SWEEP(true|false) PODS(true|false) -> out, OF
run_case() {
  TABLE_ROWS="$1"; TOPIC_LOGSTART="$2"; SWEEP_STEP="$3"; HAVE_SWEEP="$4"
  echo 100 > "$SWEEP_FILE"
  if $5; then POSTGRES_PODS=("openddil-postgres-region-east-0"); else POSTGRES_PODS=(); fi
  OVERALL_FAIL=0
  out="$(verify_aggregator 2>&1; echo "OF=$OVERALL_FAIL")"
  OF="$(printf '%s\n' "$out" | sed -n 's/^OF=//p')"
}

# --- A ----------------------------------------------------------------------
run_case 0 5 1 true true
npass="$(printf '%s\n' "$out" | grep -c ' PASS$')"
if [ "$npass" -ge 3 ] && [ "$OF" = 0 ] && ! echo "$out" | grep -q ' FAIL$' \
   && echo "$out" | grep -q 'alive (sweep-tick advanced within'; then
  pass "A: table 0, topic empty, sweep-tick advances -> $npass PASS, OVERALL_FAIL=0"
else
  fail "A: healthy (npass=$npass OF=$OF) :: $out"
fi

# --- B ----------------------------------------------------------------------
run_case 0 5 0 true true
if echo "$out" | grep -Eq 'alive \(sweep-tick advanced within 3s\) +predicted=>=1 +actual=0 +FAIL' && [ "$OF" = 1 ]; then
  pass "B: sweep-tick never advances -> alive FAIL, OVERALL_FAIL=1"
else
  fail "B: stopped aggregator (OF=$OF) :: $out"
fi

# --- C ----------------------------------------------------------------------
run_case 1 5 1 true true
if echo "$out" | grep -Eq 'region_fleet_summary rows +predicted=0 +actual=1 +FAIL' && [ "$OF" = 1 ]; then
  pass "C: table has 1 row -> FAIL"
else
  fail "C: one row (OF=$OF) :: $out"
fi

# --- D ----------------------------------------------------------------------
run_case 0 2 1 true true
if echo "$out" | grep -Eq 'region-fleet-summary/p0 \(empty: log_start == hw\) +predicted=5 +actual=2 +FAIL' && [ "$OF" = 1 ]; then
  pass "D: topic log_start < hw -> FAIL"
else
  fail "D: topic not empty (OF=$OF) :: $out"
fi

# --- E ----------------------------------------------------------------------
run_case 0 5 1 true false
if echo "$out" | grep -q 'no region-east or hq postgres pod discovered' && [ "$OF" = 1 ]; then
  pass "E: no postgres pod -> FAIL"
else
  fail "E: no pod (OF=$OF) :: $out"
fi

# --- F ----------------------------------------------------------------------
run_case 0 5 1 false true
if echo "$out" | grep -Eq 'sweep-tick alive +predicted=>=1 +actual=UNMEASURED +FAIL' && [ "$OF" = 1 ]; then
  pass "F: no sweep-tick topic -> UNMEASURED, OVERALL_FAIL=1"
else
  fail "F: no heartbeat topic (OF=$OF) :: $out"
fi

# --- G / H (real argument parser, subprocess, source-only: no cluster) -------
gout="$(RESET_SCENARIO_SOURCE_ONLY=1 bash "$SCRIPT" --declare-unmeasured aggregator-region-fleet-summary 2>&1)"
grc=$?
want='--declare-unmeasured aggregator-region-fleet-summary is retired: the regional rollup check now measures table empty, topic empty and aggregator alive. Drop the flag.'
if [ "$grc" -eq 2 ] && [ "$gout" = "$want" ] \
   && ! echo "$gout" | grep -Eq '=== PHASE|reset-scenario: namespace='; then
  pass "G: retired name -> rc 2, retired message, no phase banner"
else
  fail "G: retired name (rc=$grc) :: $gout"
fi

hout="$(RESET_SCENARIO_SOURCE_ONLY=1 bash "$SCRIPT" --declare-unmeasured foo 2>&1)"
hrc=$?
if [ "$hrc" -eq 2 ] && echo "$hout" | grep -q "unknown --declare-unmeasured name: 'foo'" \
   && ! echo "$hout" | grep -Eq '=== PHASE|reset-scenario: namespace='; then
  pass "H: unknown name -> rc 2"
else
  fail "H: unknown name (rc=$hrc) :: $hout"
fi

echo
if [ "$FAIL" -eq 0 ]; then
  echo "test_reset_aggregator_check: ALL PASS"
  exit 0
fi
echo "test_reset_aggregator_check: FAILED"
exit 1
