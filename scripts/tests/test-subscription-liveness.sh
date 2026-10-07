#!/usr/bin/env bash
# ===========================================================================
# test-subscription-liveness.sh — offline proof of
# check-subscription-liveness.sh's parsing and verdict functions against
# captured/synthetic fixtures, run through the REAL functions (sourced from
# the real script), not a reimplementation of its grep/awk.
# ===========================================================================
# The probe refuses to turn an unreadable or unparseable read into a
# confident answer (see that script's own header). This test is the proof:
# fixtures/subscriptions-3.json holds a captured-shape /subscriptions
# response with three subscriptions, with the OPTIONS object's internal key
# order deliberately different in each one, to prove the parser isn't
# relying on a fixed field order inside the part of the shape that is
# documented to vary. The script is sourced with
# OPENDDIL_SUBSCRIPTION_LIVENESS_SOURCE_ONLY=1, the same toggle
# check-effector-consumer.sh's own offline test uses, so this never runs the
# cluster guard, argument parsing, or the probe's main loop -- only loads the
# function definitions.
# ===========================================================================
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROBE="$HERE/../check-subscription-liveness.sh"
FIXTURES="$HERE/fixtures"

export OPENDDIL_SUBSCRIPTION_LIVENESS_SOURCE_ONLY=1
# shellcheck source=../check-subscription-liveness.sh
. "$PROBE"

fail=0

# ---------------------------------------------------------------------------
# parse_subscriptions: 3 subscriptions, varied OPTIONS key order.
# ---------------------------------------------------------------------------
raw="$(cat "$FIXTURES/subscriptions-3.json")"
mapfile -t lines < <(parse_subscriptions "$raw")

if [ "${#lines[@]}" -ne 3 ]; then
  echo "FAIL: parse_subscriptions(subscriptions-3.json) found ${#lines[@]} subscriptions, want 3"
  fail=1
else
  echo "PASS: parse_subscriptions(subscriptions-3.json) found 3 subscriptions"
fi

check_field() {
  local label="$1" idx="$2" want="$3"
  local got
  got="${lines[$idx]:-}"
  if [ "$got" != "$want" ]; then
    echo "FAIL: ($label) line $idx = '$got', want '$want'"
    fail=1
  else
    echo "PASS: ($label) line $idx parsed correctly"
  fi
}

check_field "sub-1-hq"          0 $'sub_136m71VJYTDJefqKNpVqNqh\topenddil-hq\tasset-cm-state\tAssetLogistics/on_cm_state_change'
check_field "sub-2-edge-01"     1 $'sub_27qPLmRX0ZqGQxqz1YVqvN\topenddil-edge-01\tasset-logistics-status\tAssetLogistics/on_logistics_status_change'
check_field "sub-3-region-east" 2 $'sub_3zK9mWqTq8Yy2rJhLpNqXv\topenddil-region-east\tcm-events\tConfigPosture/on_cm_event'

# Zero subscriptions -> the parser finds nothing, cleanly (not an error).
mapfile -t zero_lines < <(parse_subscriptions "[]")
if [ "${#zero_lines[@]}" -ne 0 ]; then
  echo "FAIL: parse_subscriptions([]) found ${#zero_lines[@]} subscriptions, want 0"
  fail=1
else
  echo "PASS: parse_subscriptions([]) found 0 subscriptions"
fi

# ---------------------------------------------------------------------------
# compute_verdict: LIVE, STALLED, IDLE, UNMEASURED (bad input flag and a
# non-numeric invocation count, i.e. a SQL parse failure).
# ---------------------------------------------------------------------------
check_verdict() {
  local label="$1" input="$2" invocations="$3" want="$4"
  local got
  got="$(compute_verdict "$input" "$invocations")"
  if [ "$got" != "$want" ]; then
    echo "FAIL: ($label) compute_verdict($input, $invocations) = $got, want $want"
    fail=1
  else
    echo "PASS: ($label) compute_verdict($input, $invocations) = $got"
  fi
}

check_verdict "live"                    "yes"   "4"     "LIVE"
check_verdict "stalled"                 "yes"   "0"     "STALLED"
check_verdict "idle"                    "no"    "n/a"   "IDLE"
check_verdict "unmeasured-sql-failure"  "yes"   "error" "UNMEASURED"
check_verdict "unmeasured-input-error"  "error" "n/a"   "UNMEASURED"

# ---------------------------------------------------------------------------
# broker_pod_for_cluster: UNMAPPED shape (a cluster name outside the fixed
# `openddil-<x>` prefix cannot be mapped to a broker pod at all).
# ---------------------------------------------------------------------------
got_pod="$(broker_pod_for_cluster "openddil-hq")"
if [ "$got_pod" != "openddil-redpanda-hq-0" ]; then
  echo "FAIL: broker_pod_for_cluster(openddil-hq) = '$got_pod', want 'openddil-redpanda-hq-0'"
  fail=1
else
  echo "PASS: broker_pod_for_cluster(openddil-hq) = '$got_pod'"
fi

got_unmapped="$(broker_pod_for_cluster "some-other-cluster")"
if [ -n "$got_unmapped" ]; then
  echo "FAIL: broker_pod_for_cluster(some-other-cluster) = '$got_unmapped', want empty (UNMAPPED)"
  fail=1
else
  echo "PASS: broker_pod_for_cluster(some-other-cluster) correctly unmapped"
fi

# ---------------------------------------------------------------------------
# compute_exit: zero subscriptions discovered is an overall FAIL on its own;
# any STALLED subscription makes the overall exit 1; all-clear is 0.
# ---------------------------------------------------------------------------
check_exit() {
  local label="$1" total="$2" stalled="$3" unmeasured="$4" want="$5"
  local got
  got="$(compute_exit "$total" "$stalled" "$unmeasured")"
  if [ "$got" != "$want" ]; then
    echo "FAIL: ($label) compute_exit($total, $stalled, $unmeasured) = $got, want $want"
    fail=1
  else
    echo "PASS: ($label) compute_exit($total, $stalled, $unmeasured) = $got"
  fi
}

check_exit "zero-subscriptions" 0 0 0 1
check_exit "any-stalled"        3 1 0 1
check_exit "any-unmeasured"     3 0 1 1
check_exit "all-clear"          3 0 0 0

if [ "$fail" -ne 0 ]; then
  echo "test-subscription-liveness.sh: FAIL"
  exit 1
fi
echo "test-subscription-liveness.sh: ALL PASS"
exit 0
