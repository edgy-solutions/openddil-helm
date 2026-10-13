#!/usr/bin/env bash
# ===========================================================================
# test_reset_quick.sh -- offline proof for `reset-scenario.sh --quick` and for
# restart-exercise.sh's refusal of it, against the REAL run_reset_sequence,
# flag parser and wrapper (sourced the same way as test_reset_ownership.sh;
# see that file's header for the SOURCE_ONLY seam).
#
# Every phase function is replaced by a stub that appends its label to a call
# log, so the test compares the SEQUENCE of calls, not a count.
#
# Cases:
#   A. --quick sequence is exactly pre-flight, 2, 3, 3b, 4, 5, 6, 7, 9
#   B. phases 1, 8, 10 and write_exercise_reset_record are not called
#   C. start and end banners appear and name the skipped phases
#   D. every refused flag combination exits 1 and runs nothing
#   E. --quick --dry-run runs the same sequence, nothing executed
#   F. restart-exercise.sh --quick exits 1 and never invokes the reset script
#   G. control: a full (non-quick) run calls all of it, in order
#
# RED CHECK: SCRIPT=<path> / WRAPPER=<path> run this against a mutated copy.
# ===========================================================================
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${SCRIPT:-$HERE/../reset-scenario.sh}"
WRAPPER="${WRAPPER:-$HERE/../restart-exercise.sh}"

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

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
LOG="$T/calls.log"

# --- stubs: each records its label -------------------------------------------
phase1_baseline()               { echo "1" >> "$LOG"; }
phase4_capture_pass()           { echo "preflight" >> "$LOG"; CAPTURED_TOPICS=(); }
assert_consumers_declared()     { return 0; }
phase2_quiesce()                { echo "2" >> "$LOG"; }
phase3_restate()                { echo "3" >> "$LOG"; }
phase3b_writer_census()         { echo "3b" >> "$LOG"; }
phase4_topics()                 { echo "4" >> "$LOG"; }
phase5_aggregator()             { echo "5" >> "$LOG"; }
phase6_stores()                 { echo "6" >> "$LOG"; }
phase7_electric()               { echo "7" >> "$LOG"; }
phase8_zero()                   { echo "8" >> "$LOG"; }
phase9_restore_producers()      { echo "9" >> "$LOG"; }
phase10_subscription_liveness() { echo "10" >> "$LOG"; }
write_exercise_reset_record()   { echo "record" >> "$LOG"; }

seq_of() { tr '\n' ' ' < "$LOG" | sed 's/ $//'; }

QUICK_SEQ="preflight 2 3 3b 4 5 6 7 9"
FULL_SEQ="1 preflight 2 3 3b 4 5 6 7 8 9 10 record"

# run_main QUICK DRY -> runs the real sequence in a subshell; out in $T/out
run_main() {
  : > "$LOG"
  ( QUICK="$1"; DRY_RUN="$2"; run_reset_sequence ) > "$T/out" 2> "$T/err"
  RC=$?
}

# --- A, B, C: quick ------------------------------------------------------------
run_main true false
[ "$RC" -eq 0 ] && pass "A: quick exits 0" || fail "A: quick rc=$RC"
[ "$(seq_of)" = "$QUICK_SEQ" ] && pass "A: sequence is exactly '$QUICK_SEQ'" \
  || fail "A: sequence was '$(seq_of)', expected '$QUICK_SEQ'"
for p in 1 8 10 record; do
  grep -qx "$p" "$LOG" && fail "B: '$p' was called in quick mode" || pass "B: '$p' not called"
done
BANNER="QUICK RESET: state cleared, NOT MEASURED. Skipped: phase 1 baseline, phase 8 zero assertion, phase 10 subscription liveness. No exercise reset record was written."
[ "$(grep -cxF "$BANNER" "$T/out")" -eq 2 ] && pass "C: banner printed exactly twice, naming the skipped phases" \
  || fail "C: banner count $(grep -cxF "$BANNER" "$T/out"), expected 2"
[ "$(head -1 "$T/out")" = "$BANNER" ] && pass "C: banner is the first line (start)" || fail "C: banner not first"
[ "$(tail -1 "$T/out")" = "$BANNER" ] && pass "C: banner is the last line (end)" || fail "C: banner not last"

# --- G: control, a full run -------------------------------------------------------
run_main false false
[ "$(seq_of)" = "$FULL_SEQ" ] && pass "G: full run sequence is '$FULL_SEQ'" \
  || fail "G: full sequence was '$(seq_of)'"
grep -q "QUICK RESET" "$T/out" && fail "G: full run printed the quick banner" || pass "G: full run prints no quick banner"

# --- E: --quick --dry-run ---------------------------------------------------------------
run_main true true
[ "$RC" -eq 0 ] && [ "$(seq_of)" = "$QUICK_SEQ" ] && pass "E: --quick --dry-run runs the same sequence" \
  || fail "E: dry-run rc=$RC sequence '$(seq_of)'"
grep -q "record" "$LOG" && fail "E: dry-run quick wrote a record" || pass "E: dry-run quick writes no record"

# --- D: refused combinations (real flag parser, fresh process state) ----------------------
mkdir -p "$T/bin"
cat > "$T/bin/kubectl" <<KEOF
#!/usr/bin/env bash
echo "\$*" >> "$T/kubectl.log"
KEOF
chmod +x "$T/bin/kubectl"
refuse() {  # refuse FLAGS...
  : > "$T/kubectl.log"
  ( export PATH="$T/bin:$PATH"; set -- "$@"; . "$SCRIPT" ) > "$T/rout" 2> "$T/rerr"
  RC=$?
  if [ "$RC" -eq 1 ] && grep -q "usage error: --quick cannot be combined" "$T/rerr" \
     && [ ! -s "$T/kubectl.log" ] && ! grep -q "PHASE\|reset-scenario: namespace" "$T/rout"; then
    pass "D: '$*' -> exit 1, nothing run"
  else
    fail "D: '$*' -> rc=$RC (expected 1, usage error, no cluster call)"; cat "$T/rerr" | head -3
  fi
}
refuse --quick --baseline-only
refuse --quick --verify-only
refuse --quick --census-only
refuse --quick --writer-census-only
refuse --quick --red-check-topic-config
refuse --quick --red-check-quiesce
refuse --quick --red-check-electric
refuse --quick --declare-unmeasured aggregator-region-fleet-summary
refuse --verify-only --quick

# --- F: restart-exercise.sh refuses --quick -------------------------------------------------
cat > "$T/reset-stub.sh" <<SEOF
#!/usr/bin/env bash
echo "stub reset ran: \$*" >> "$T/reset-ran.log"
exit 0
SEOF
chmod +x "$T/reset-stub.sh"
: > "$T/reset-ran.log"
PATH="$T/bin:$PATH" RESET_SCRIPT="$T/reset-stub.sh" bash "$WRAPPER" --release rel --namespace ns --quick > "$T/f.out" 2> "$T/f.err"
RC=$?
if [ "$RC" -eq 1 ] && [ ! -s "$T/reset-ran.log" ] && grep -q -- "--quick refused" "$T/f.err"; then
  pass "F: restart-exercise --quick -> exit 1, reset never invoked"
else fail "F: rc=$RC reset-ran=$(cat "$T/reset-ran.log") err=$(cat "$T/f.err")"; fi
PATH="$T/bin:$PATH" RESET_SCRIPT="$T/reset-stub.sh" bash "$WRAPPER" --release rel --namespace ns --dry-run --quick > "$T/f2.out" 2> "$T/f2.err"
RC=$?
{ [ "$RC" -eq 1 ] && [ ! -s "$T/reset-ran.log" ]; } && pass "F: --quick among other args is refused too" || fail "F2: rc=$RC"

echo
if [ "$FAIL" -eq 0 ]; then echo "test_reset_quick: ALL PASS"; exit 0; fi
echo "test_reset_quick: FAILED"; exit 1
