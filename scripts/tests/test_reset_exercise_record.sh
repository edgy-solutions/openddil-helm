#!/usr/bin/env bash
# ===========================================================================
# test_reset_exercise_record.sh -- offline proof for the exercise-reset-
# record write in reset-scenario.sh (write_exercise_reset_record and its one
# call site), against the REAL function, not a reimplementation of it.
# ===========================================================================
#
# reset-scenario.sh talks to a live cluster (require-cluster.sh's own guard
# `exit`s if it can't), so this test sources it with
# RESET_SCENARIO_SOURCE_ONLY=1 to load its function definitions without
# running the cluster check or any phase -- same escape hatch every other
# scripts/tests/test_reset_*.sh file uses.
#
# `kubectl` is stubbed as a plain shell function (not the compose shim,
# which shells out to the real `docker` binary and must never be invoked
# here) so every case below is a controlled, offline fixture.
#
# Cases:
#   A. Deployment present, OVERALL_FAIL=0 -> record applied, carrying
#      measured_zero_at and verdict.
#   B. Deployment absent -> nothing applied, the explanatory line printed.
#   C. A halted reset -> write_exercise_reset_record is never even called
#      (halt_reset exits directly, before RUN_COMPLETED is ever set), so
#      nothing is applied.
# ===========================================================================
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${SCRIPT:-$HERE/../reset-scenario.sh}"

NS="openddil"
RELEASE="openddil"
export NS RELEASE

RESET_SCENARIO_SOURCE_ONLY=1
export RESET_SCENARIO_SOURCE_ONLY
# `source` inherits this script's OWN positional parameters -- cleared here
# so reset-scenario.sh's arg-parsing while loop (still top-level code, runs
# before the SOURCE_ONLY guard) sees $#=0 instead of possibly hitting its
# own "unknown flag" branch, which calls `exit` and would kill this test.
set --
# shellcheck source=../reset-scenario.sh
. "$SCRIPT"
# reset-scenario.sh's own `set -euo pipefail` now applies to this shell too.
# This test deliberately calls halt_reset, which is SUPPOSED to exit non-
# zero, and inspects that exit code itself in a subshell -- so -e has to
# come back off here or the first such call would kill this test process.
set +e

FAIL=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAIL=1; }

APPLY_LOG="$(mktemp)"
DEPLOY_PRESENT=true
trap 'rm -f "$APPLY_LOG"' EXIT

# A controlled stand-in for the real kubectl -- answers only the two calls
# write_exercise_reset_record makes, by the SAME shapes reset-scenario.sh
# issues them in.
kubectl() {
  local argstr="$*"
  case "$argstr" in
    "get deploy -n $NS ${RELEASE}-exercise-control -o name")
      if $DEPLOY_PRESENT; then
        echo "deployment.apps/${RELEASE}-exercise-control"
        return 0
      fi
      return 1
      ;;
    "create configmap ${RELEASE}-exercise-reset-record -n $NS"*"--dry-run=client -o yaml")
      # A real `kubectl create configmap --dry-run=client -o yaml` builds its
      # output from ARGV, not stdin (there is none) -- so this stub does the
      # same: pull the --from-literal=record.json=VALUE argument back out
      # and print a minimal ConfigMap carrying it, for "apply -f -" below to
      # receive over the pipe exactly as a real apply would.
      local -a args=("$@")
      local lit=""
      local a
      for a in "${args[@]}"; do
        case "$a" in
          --from-literal=record.json=*) lit="${a#--from-literal=record.json=}" ;;
        esac
      done
      printf 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: %s-exercise-reset-record\ndata:\n  record.json: %s\n' "$RELEASE" "$lit"
      return 0
      ;;
    "apply -f -")
      cat >> "$APPLY_LOG"
      return 0
      ;;
    *)
      echo "test stub: unhandled kubectl call ($argstr)" >&2
      return 0
      ;;
  esac
}

# --- case A: deployment present, OVERALL_FAIL=0 -> apply called with the record
DEPLOY_PRESENT=true
OVERALL_FAIL=0
: > "$APPLY_LOG"
out="$(write_exercise_reset_record 2>&1)"
if grep -q "measured_zero_at" "$APPLY_LOG" && grep -q '"verdict": "PASS"' "$APPLY_LOG"; then
  pass "A: present + success -- record applied with measured_zero_at and verdict"
else
  fail "A: present + success -- record not applied as expected ($out / $(cat "$APPLY_LOG"))"
fi

# --- case B: deployment absent -> no apply, the explanatory line printed
DEPLOY_PRESENT=false
: > "$APPLY_LOG"
out="$(write_exercise_reset_record 2>&1)"
if [ ! -s "$APPLY_LOG" ]; then
  pass "B: absent -- nothing applied"
else
  fail "B: absent -- apply ran anyway"
fi
if echo "$out" | grep -q "not written"; then
  pass "B: absent -- explanatory line printed"
else
  fail "B: absent -- no explanatory line ($out)"
fi

# --- case C: a halted reset never calls write_exercise_reset_record at all.
# halt_reset prints "HALT: ..." and exits 2 directly -- it never sets
# RUN_COMPLETED and never reaches the call site. Run in a subshell so this
# test process survives the exit.
DEPLOY_PRESENT=true
: > "$APPLY_LOG"
out="$( ( halt_reset "simulated halt for this test" "state: n/a" ) 2>&1 )"
rc=$?
if [ "$rc" -eq 2 ] && [ ! -s "$APPLY_LOG" ]; then
  pass "C: halted -- no apply (rc=$rc)"
else
  fail "C: halted -- expected rc=2 and no apply, got rc=$rc, apply_log=$(cat "$APPLY_LOG")"
fi

# --- case D: dry run, deployment present -> nothing applied, line printed
DEPLOY_PRESENT=true
DRY_RUN=true
: > "$APPLY_LOG"
out="$(write_exercise_reset_record 2>&1)"
DRY_RUN=false
if [ ! -s "$APPLY_LOG" ] && echo "$out" | grep -q "dry run"; then
  pass "D: dry run -- nothing applied, dry-run line printed"
else
  fail "D: dry run -- apply ran or no line ($out / $(cat "$APPLY_LOG"))"
fi

echo
if [ "$FAIL" -eq 0 ]; then
  echo "test_reset_exercise_record: ALL PASS"
  exit 0
fi
echo "test_reset_exercise_record: FAILED"
exit 1
