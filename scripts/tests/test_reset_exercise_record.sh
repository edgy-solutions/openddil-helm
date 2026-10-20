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
#   C. A halted reset -> the EXIT trap writes a HALTED record (halted_in,
#      reason, completed; measured_zero_at null).
#   F. A completed run that did not pass -> FAIL record, failed_in names the
#      phase; measured_zero_at null.
#   G. A DRY_RUN halt applies nothing.
#   H. The record carries electric_cleared and mode.
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

# --- case C: a halted reset writes a HALTED record from the EXIT trap, naming
# where it halted and why, with a null measured_zero_at. The subshell installs
# the real trap (run_reset_sequence does the same) and calls the real halt_reset.
DEPLOY_PRESENT=true
: > "$APPLY_LOG"
out="$( ( trap 'on_reset_exit' EXIT; RESET_RUN=true; CURRENT_PHASE="4 topics"; PHASES_DONE=("2 quiesce" "3 restate"); halt_reset "simulated halt for this test" "state: n/a" ) 2>&1 )"
rc=$?
if [ "$rc" -eq 2 ] && grep -q '"verdict": "HALTED"' "$APPLY_LOG"    && grep -q '"measured_zero_at": null' "$APPLY_LOG"    && grep -q '"halted_in": "4 topics"' "$APPLY_LOG"    && grep -q '"reason": "simulated halt for this test"' "$APPLY_LOG"    && grep -q '"completed": \["2 quiesce", "3 restate"\]' "$APPLY_LOG"; then
  pass "C: halted -- HALTED record with halted_in, reason, completed (rc=$rc)"
else
  fail "C: halted -- expected rc=2 and a HALTED record, got rc=$rc, apply_log=$(cat "$APPLY_LOG")"
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

# --- case E: the record carries the bulk cancel's counts ([] when none ran)
DEPLOY_PRESENT=true
OVERALL_FAIL=0
RESTATE_BULK_CANCEL_JSON=()
: > "$APPLY_LOG"
write_exercise_reset_record >/dev/null 2>&1
if grep -q '"restate_bulk_cancel": \[\]' "$APPLY_LOG"; then
  pass "E1: no bulk cancel -- restate_bulk_cancel is []"
else
  fail "E1: no bulk cancel -- expected restate_bulk_cancel [] ($(cat "$APPLY_LOG"))"
fi
RESTATE_BULK_CANCEL_JSON=('{"pod": "rs-a-0", "confirmed_open": 10000, "open_before": 10000, "open_after": 200, "rounds": 21, "kill_rounds": 0, "seconds": 68}'
                          '{"pod": "rs-b-0", "confirmed_open": 400, "open_before": 400, "open_after": 120, "rounds": 1, "kill_rounds": 1, "seconds": 3}')
: > "$APPLY_LOG"
write_exercise_reset_record >/dev/null 2>&1
if grep -q '"restate_bulk_cancel": \[{"pod": "rs-a-0", "confirmed_open": 10000,.*}, {"pod": "rs-b-0", "confirmed_open": 400,.*"kill_rounds": 1, "seconds": 3}]' "$APPLY_LOG"; then
  pass "E2: two drained pods -- both objects in the record, in order"
else
  fail "E2: two drained pods -- record lacks them ($(cat "$APPLY_LOG"))"
fi
RESTATE_BULK_CANCEL_JSON=()

# --- case F: a completed run that did not pass writes FAIL, failed_in names
# the phase where OVERALL_FAIL went non-zero, and measured_zero_at is null.
DEPLOY_PRESENT=true
OVERALL_FAIL=0
FAILED_IN=()
_ph8() { OVERALL_FAIL=1; }
_ph_ok() { :; }
for spec in "7 electric:_ph_ok" "8 zero assertion:_ph8" "9 restore:_ph_ok"; do
  _b=$OVERALL_FAIL; "${spec#*:}"; _note_fail "${spec%%:*}" "$_b"
done
: > "$APPLY_LOG"
write_exercise_reset_record FAIL >/dev/null 2>&1
if grep -q '"verdict": "FAIL"' "$APPLY_LOG" && grep -q '"measured_zero_at": null' "$APPLY_LOG"    && grep -q '"failed_in": \["8 zero assertion"\]' "$APPLY_LOG" && grep -q '"failed_at": "' "$APPLY_LOG"; then
  pass "F: completed FAIL -- FAIL record, failed_in names phase 8 only"
else
  fail "F: completed FAIL -- record wrong ($(cat "$APPLY_LOG"))"
fi
OVERALL_FAIL=0; FAILED_IN=()

# --- case G: a DRY_RUN halt applies nothing (the trap runs, the writer refuses).
: > "$APPLY_LOG"
out="$( ( DRY_RUN=true; trap 'on_reset_exit' EXIT; RESET_RUN=true; CURRENT_PHASE="4 topics"; halt_reset "dry halt" ) 2>&1 )"
rc=$?
if [ "$rc" -eq 2 ] && [ ! -s "$APPLY_LOG" ] && echo "$out" | grep -q "dry run"; then
  pass "G: dry-run halt -- nothing applied, dry-run line printed"
else
  fail "G: dry-run halt -- rc=$rc apply_log=$(cat "$APPLY_LOG") out=$out"
fi

# --- case H: every record carries electric_cleared and mode.
ELECTRIC_CLEARED_JSON=('{"instance": "openddil-electric-sync", "mode": "pvc", "pvc": "c", "job": "j", "result": "cleared", "entries_before": 7}')
: > "$APPLY_LOG"
write_exercise_reset_record >/dev/null 2>&1
if grep -q '"electric_cleared": \[{"instance": "openddil-electric-sync", "mode": "pvc"' "$APPLY_LOG"    && grep -q '"mode": "full"' "$APPLY_LOG" && grep -q '"verdict": "PASS"' "$APPLY_LOG"; then
  pass "H: electric_cleared and mode present on a PASS record"
else
  fail "H: electric_cleared/mode missing ($(cat "$APPLY_LOG"))"
fi
ELECTRIC_CLEARED_JSON=()

echo
if [ "$FAIL" -eq 0 ]; then
  echo "test_reset_exercise_record: ALL PASS"
  exit 0
fi
echo "test_reset_exercise_record: FAILED"
exit 1
