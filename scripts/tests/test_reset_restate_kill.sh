#!/usr/bin/env bash
# ===========================================================================
# test_reset_restate_kill.sh — offline proof for the kill escalation inside
# restate_clear_pass (reset-scenario.sh, phase 3: restate_clear_pass /
# phase3_restate), against the REAL functions (sourced the same way as
# test_reset_restate_halt.sh; see that file's header for the SOURCE_ONLY
# seam):
#
#   An id read as open is cancelled the first time this pod sees it in this
#   phase3_restate run. If it is STILL open the next time this pod reads it,
#   cancel already had its chance (cancel is cooperative — the service has
#   to run to observe it) and this pass kills it instead: a diagnostic row
#   is printed first, then `restate invocations kill`, falling back through
#   the admin API (PATCH, then DELETE ?mode=kill) the same way cancel falls
#   back to DELETE ?mode=cancel. A halt at the pass bound names every id
#   this pod had to kill.
#
# Restate is replaced by a small file-backed model: $M/<pod>.ids.<pass> is
# the fixed list of open ids this pod reads on pass <pass> (prepared by
# seed_ids, below — the model does not simulate cancel/kill actually
# removing an id; each case simply states what pass the id disappears on,
# which is all these cases need to prove). $M/<pod>.log records every
# kubectl action, in order, for cases that need to check exactly which
# fallback ran.
#
# Mutation check: SCRIPT=<path> runs this against another copy of
# reset-scenario.sh. Flipping any one of the following in that copy must
# turn the named case from PASS to FAIL, which is how this test was proven
# to test anything:
#   - the "seen before" check in restate_clear_pass forced to always true
#     (kill on first sighting) -> case B fails (B expects no kill at all).
#   - the per-pod record never written (the id is never remembered as
#     cancelled) -> case A fails (A expects a kill on the second sighting).
#   - the kill fallback chain (PATCH, then DELETE) removed -> case D fails
#     (D expects PATCH, and DELETE after PATCH also fails).
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

M="$(mktemp -d)"
trap 'rm -rf "$M"' EXIT

# --- the Restate model -----------------------------------------------------

# seed_ids POD PASS1-IDS PASS2-IDS ... — one argument per pass, each a
# space-separated list of ids open on that pass ("" for none that pass).
seed_ids() {
  local pod="$1" n=0 ids
  shift
  rm -f "$M/$pod".ids.* "$M/$pod.step" "$M/$pod.log" \
        "$M/$pod.kill_cli_fails" "$M/$pod.patch_fails" "$M/$pod.diag_empty"
  for ids in "$@"; do
    n=$((n + 1))
    : > "$M/$pod.ids.$n"
    if [ -n "$ids" ]; then printf '%s\n' $ids >> "$M/$pod.ids.$n"; fi
  done
}

restate_json() {
  local pod="$1" sql="$2" step f id
  case "$sql" in
    *"where status <> 'completed'"*)
      step="$(cat "$M/$pod.step" 2>/dev/null || echo 0)"
      step=$((step + 1))
      printf '%s' "$step" > "$M/$pod.step"
      f="$M/$pod.ids.$step"
      if [ -s "$f" ]; then
        awk 'BEGIN{printf "["} {printf "%s{\"id\":\"%s\"}", (NR>1?",":""), $1} END{print "]"}' "$f"
      else
        echo "[]"
      fi
      ;;
    *"where id = "*)
      if [ -e "$M/$pod.diag_empty" ]; then
        printf ''
      else
        id="$(printf '%s' "$sql" | sed -E "s/.*id = '([^']*)'.*/\1/")"
        printf '[{"id":"%s","target":"AssetLogistics-%s","status":"running","retry_count":2,"last_failure_error_code":"E1","last_failure":"boom","pinned_deployment_id":"dep-1"}]' "$id" "$id"
      fi
      ;;
    *) echo "[]" ;;
  esac
}

restate_count() {
  local pod="$1" sql="$2" step f
  case "$sql" in
    *"from state"*) echo 0 ;;
    *"status = 'scheduled'"* | *"status <> 'completed'"*)
      step="$(cat "$M/$pod.step" 2>/dev/null || echo 0)"
      f="$M/$pod.ids.$step"
      if [ -s "$f" ]; then grep -c . "$f"; else echo 0; fi
      ;;
    *) echo 0 ;;
  esac
}

kubectl() {
  local args="$*" pod id
  case "$args" in
    "exec -n "*)
      pod="$4"
      case "$args" in
        *"invocations cancel "*)
          id="${args##* }"
          echo "cancel $id" >> "$M/$pod.log"
          return 0 ;;
        *"invocations kill "*)
          id="${args##* }"
          echo "kill-cli $id" >> "$M/$pod.log"
          [ -e "$M/$pod.kill_cli_fails" ] && return 1
          return 0 ;;
        *"PATCH"*)
          id="$(printf '%s' "$args" | sed -E 's#.*invocations/([^/]+)/kill.*#\1#')"
          echo "patch-kill $id" >> "$M/$pod.log"
          [ -e "$M/$pod.patch_fails" ] && return 1
          return 0 ;;
        *"DELETE"*"mode=kill"*)
          id="$(printf '%s' "$args" | sed -E 's#.*invocations/([^?]+)\?mode=kill.*#\1#')"
          echo "delete-kill $id" >> "$M/$pod.log"
          return 0 ;;
        *"DELETE"*"mode=cancel"*)
          id="$(printf '%s' "$args" | sed -E 's#.*invocations/([^?]+)\?mode=cancel.*#\1#')"
          echo "delete-cancel $id" >> "$M/$pod.log"
          return 0 ;;
        *) return 0 ;;
      esac
      ;;
    "scale "*) echo "kubectl $args" >> "$M/scale.log"; return 0 ;;
    *) return 0 ;;
  esac
}

# No wall-clock waiting: the model is keyed by pass number, not by time, so
# the gap between the two zero-reads is a no-op here (same seam the halt
# test uses for its "time passing" cases).
sleep() { :; }

DRY_RUN=false
SKIP_RESTATE=false
RESTATE_CLEAR_MAX_PASSES=4

# --- case A: open on pass 1, still open on pass 2 (survives cancel), gone
# on pass 3. Expect: cancel on pass 1, the "survived cancel:" line and a
# kill naming pass 1 on pass 2, then a clean finish.
seed_ids pod-a "x1" "x1" ""
RESTATE_PODS=(pod-a)
out="$( (set -e; phase3_restate) 2>&1 )"; rc=$?
[ "$rc" -eq 0 ] && pass "A: phase 3 completed (rc 0)" || fail "A: rc=$rc, expected 0"
grep -q '^-> cancel invocation x1 on pod-a$' <<<"$out" && pass "A: cancelled on pass 1" \
  || fail "A: no cancel line for x1"
grep -q '^   survived cancel: .*"id":"x1"' <<<"$out" && pass "A: diagnostic row printed" \
  || fail "A: no survived-cancel diagnostic line"
grep -q '^-> kill invocation x1 on pod-a (survived cancel in pass 1)$' <<<"$out" \
  && pass "A: killed on pass 2, naming the cancel pass" \
  || fail "A: no kill line naming pass 1"
grep -q 'pod-a: clear after 3 pass(es), two zero reads' <<<"$out" && pass "A: cleared after 3 passes" \
  || fail "A: did not clear after 3 passes"
[ "$(grep -c '^kill-cli x1$' "$M/pod-a.log")" = "1" ] && pass "A: kill CLI called exactly once" \
  || fail "A: kill CLI not called exactly once"

# --- case A2: same shape, but the diagnostic read comes back empty (a
# column this Restate version lacks, or an unreadable response). It must
# print "unreadable", never fail the pass, and still kill and clear.
seed_ids pod-a2 "w1" "w1" ""
touch "$M/pod-a2.diag_empty"
RESTATE_PODS=(pod-a2)
out="$( (set -e; phase3_restate) 2>&1 )"; rc=$?
[ "$rc" -eq 0 ] && pass "A2: unreadable diagnostic — phase 3 still completed (rc 0)" \
  || fail "A2: rc=$rc, expected 0"
grep -q '^   survived cancel: unreadable$' <<<"$out" && pass "A2: prints unreadable" \
  || fail "A2: did not print unreadable"
grep -q '^-> kill invocation w1 on pod-a2' <<<"$out" && pass "A2: still killed" \
  || fail "A2: did not still kill"

# --- case B: cancelled on pass 1, gone by pass 2. No kill, ever.
seed_ids pod-b "y1" ""
RESTATE_PODS=(pod-b)
out="$( (set -e; phase3_restate) 2>&1 )"; rc=$?
[ "$rc" -eq 0 ] && pass "B: phase 3 completed (rc 0)" || fail "B: rc=$rc, expected 0"
grep -q '^-> cancel invocation y1 on pod-b$' <<<"$out" && pass "B: cancelled once" \
  || fail "B: no cancel line for y1"
grep -q 'kill' <<<"$out" && fail "B: a kill line appeared" || pass "B: no kill line"
[ -e "$M/pod-b.log" ] && grep -q 'kill' "$M/pod-b.log" \
  && fail "B: kill was issued against Restate" || pass "B: kill was never issued"

# --- case C: a timer re-arms under a new id between passes. The new id is
# cancelled, like any other first sighting — not killed.
seed_ids pod-c "z1" "z2" ""
RESTATE_PODS=(pod-c)
out="$( (set -e; phase3_restate) 2>&1 )"; rc=$?
[ "$rc" -eq 0 ] && pass "C: phase 3 completed (rc 0)" || fail "C: rc=$rc, expected 0"
grep -q '^-> cancel invocation z1 on pod-c$' <<<"$out" && grep -q '^-> cancel invocation z2 on pod-c$' <<<"$out" \
  && pass "C: both ids cancelled" || fail "C: z1 and/or z2 not both cancelled"
grep -q 'kill' <<<"$out" && fail "C: a kill line appeared for the re-armed id" || pass "C: re-armed id was cancelled, not killed"

# --- case D: the kill CLI fails. D1: PATCH then succeeds, so DELETE is
# never tried. D2: PATCH also fails, so DELETE is tried too. Neither sub-case
# aborts the pass.
seed_ids pod-d1 "d1" "d1" ""
touch "$M/pod-d1.kill_cli_fails"
RESTATE_PODS=(pod-d1)
out="$( (set -e; phase3_restate) 2>&1 )"; rc=$?
[ "$rc" -eq 0 ] && pass "D1: CLI kill fails, PATCH succeeds — pass does not abort (rc 0)" \
  || fail "D1: rc=$rc, expected 0"
[ "$(grep -c '^kill-cli d1$' "$M/pod-d1.log")" = "1" ] \
  && [ "$(grep -c '^patch-kill d1$' "$M/pod-d1.log")" = "1" ] \
  && [ "$(grep -c '^delete-kill d1$' "$M/pod-d1.log")" = "0" ] \
  && pass "D1: PATCH called, DELETE not needed" || fail "D1: wrong fallback sequence in $M/pod-d1.log"

seed_ids pod-d2 "d2" "d2" ""
touch "$M/pod-d2.kill_cli_fails" "$M/pod-d2.patch_fails"
RESTATE_PODS=(pod-d2)
out="$( (set -e; phase3_restate) 2>&1 )"; rc=$?
[ "$rc" -eq 0 ] && pass "D2: CLI kill and PATCH both fail — pass still does not abort (rc 0)" \
  || fail "D2: rc=$rc, expected 0"
[ "$(grep -c '^kill-cli d2$' "$M/pod-d2.log")" = "1" ] \
  && [ "$(grep -c '^patch-kill d2$' "$M/pod-d2.log")" = "1" ] \
  && [ "$(grep -c '^delete-kill d2$' "$M/pod-d2.log")" = "1" ] \
  && pass "D2: PATCH called, then DELETE after PATCH also failed" || fail "D2: wrong fallback sequence in $M/pod-d2.log"

# --- case E: the id survives cancel AND every kill attempt. The whole reset
# must halt at the pass bound and its context must name the killed id.
seed_ids pod-e "e1" "e1" "e1"
RESTATE_PODS=(pod-e)
RESTATE_CLEAR_MAX_PASSES=3
out="$( (
  set -e
  RESET_RUN=true; PHASES_DONE=("1 baseline" "pre-flight" "2 quiesce")
  type on_reset_exit >/dev/null 2>&1 && trap on_reset_exit EXIT
  run_phase "3 restate" phase3_restate
  echo "PHASE-4-RAN"
) 2>&1 )"; rc=$?
[ "$rc" -eq 2 ] && pass "E: stuck past cancel and kill — exit 2" || fail "E: rc=$rc, expected 2"
grep -q "RESET HALTED" <<<"$out" && pass "E: RESET HALTED block" || fail "E: no RESET HALTED block"
grep -q "halted in: 3 restate" <<<"$out" && pass "E: names the phase" || fail "E: phase not named"
grep -q "pod-e residue (keys rows scheduled open): 0 0 1 1" <<<"$out" && pass "E: names pod-e's residue" \
  || fail "E: pod-e residue not named"
grep -q "Invocations killed on pod-e: e1" <<<"$out" && pass "E: names the killed id" \
  || fail "E: killed id not named in the halt context"
grep -q "PHASE-4-RAN" <<<"$out" && fail "E: a later phase ran after the halt" || pass "E: no later phase ran"

echo
if [ "$FAIL" -eq 0 ]; then echo "test_reset_restate_kill: ALL PASS"; exit 0; fi
echo "test_reset_restate_kill: FAILED"; exit 1
