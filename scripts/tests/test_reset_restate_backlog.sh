#!/usr/bin/env bash
# ===========================================================================
# test_reset_restate_backlog.sh — offline proof for three properties of
# restate_clear_pass / the signal handling in reset-scenario.sh, against the
# REAL functions (sourced via RESET_SCENARIO_SOURCE_ONLY, same seam as
# test_reset_restate_kill.sh):
#
#   1. A pod with more open invocations than RESTATE_MAX_OPEN (default 300)
#      halts the reset (exit 2) BEFORE any cancel is issued, names the pod,
#      the count and --skip-restate, and the scale-down restores still run.
#   2. A cancel that fails with "No invocations found" (the invocation
#      completed between the list and the cancel) prints "already completed",
#      runs no admin-API fallback, and is not remembered as cancelled, so the
#      next sighting cancels again rather than escalating to kill.
#   3. TERM turns into a normal exit (143) and the EXIT trap restores the
#      scale-downs. NOTE: this runs bash as an ordinary process, not PID 1;
#      PID 1 semantics (TERM ignored without a handler) cannot be reproduced
#      here, so the case proves the handler -> EXIT trap -> restore chain.
#
# SCRIPT=<path> runs this against another copy of reset-scenario.sh (used to
# prove each case fails against the pre-change script).
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

# The model: $M/<pod>.ids.<pass> is the open-id list read on pass <pass>;
# $M/<pod>.open_override, if present, is the open count restate_count reports.
seed_ids() {
  local pod="$1" n=0 ids
  shift
  rm -f "$M/$pod".ids.* "$M/$pod.step" "$M/$pod.log" "$M/$pod.open_override" "$M/$pod.cancel_gone"
  for ids in "$@"; do
    n=$((n + 1))
    : > "$M/$pod.ids.$n"
    if [ -n "$ids" ]; then printf '%s\n' $ids >> "$M/$pod.ids.$n"; fi
  done
}

restate_json() {
  local pod="$1" sql="$2" step f
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
    *) echo "[]" ;;
  esac
}

restate_count() {
  local pod="$1" sql="$2" step f
  case "$sql" in
    *"from state"*) echo 0 ;;
    *"status = 'scheduled'"*) echo 0 ;;
    *"status <> 'completed'"*)
      if [ -e "$M/$pod.open_override" ]; then cat "$M/$pod.open_override"; return; fi
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
          if [ -e "$M/$pod.cancel_gone" ]; then
            echo "Error: No invocations found for query $id! Note that the cancel command only works on non-completed invocations" >&2
            return 1
          fi
          return 0 ;;
        *"invocations kill "*) echo "kill-cli ${args##* }" >> "$M/$pod.log"; return 0 ;;
        *"PATCH"*) echo "patch-kill" >> "$M/$pod.log"; return 0 ;;
        *"DELETE"*"mode=kill"*) echo "delete-kill" >> "$M/$pod.log"; return 0 ;;
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

sleep() { :; }

DRY_RUN=false
SKIP_RESTATE=false
RESTATE_CLEAR_MAX_PASSES=4

# --- case 1: backlog over the limit halts before any cancel ----------------
seed_ids pod-a "a1 a2 a3"
echo 301 > "$M/pod-a.open_override"
RESTATE_PODS=(pod-a)
: > "$M/scale.log"
out="$( (
  set -e
  PRODUCER_DEPLOYS=(fake-producer); ORIG_REPLICAS[fake-producer]=1
  SCALES_ARMED=true; SCALES_RESTORED=false
  RESET_RUN=true; PHASES_DONE=("1 baseline" "pre-flight" "2 quiesce")
  type on_reset_exit >/dev/null 2>&1 && trap on_reset_exit EXIT
  run_phase "3 restate" phase3_restate
  echo "PHASE-4-RAN"
) 2>&1 )"; rc=$?
[ "$rc" -eq 2 ] && pass "1: backlog 301 - exit 2" || fail "1: rc=$rc, expected 2"
grep -q "pod-a" <<<"$out" && grep -q "301" <<<"$out" && pass "1: names the pod and the count" \
  || fail "1: pod and/or count not named"
grep -q -- "--skip-restate" <<<"$out" && pass "1: names --skip-restate" || fail "1: --skip-restate not named"
{ [ ! -e "$M/pod-a.log" ] || ! grep -q '^cancel ' "$M/pod-a.log"; } && pass "1: no cancel was issued" \
  || fail "1: a cancel was issued"
grep -q "PHASE-4-RAN" <<<"$out" && fail "1: a later phase ran" || pass "1: no later phase ran"
grep -q "scale deploy -n openddil fake-producer --replicas=1" "$M/scale.log" \
  && pass "1: scale-down restore ran" || fail "1: scale-down restore did not run"

# --- case 2: cancel of an already-completed id ------------------------------
seed_ids pod-b "b1" "b1" ""
touch "$M/pod-b.cancel_gone"
RESTATE_PODS=(pod-b)
out="$( (set -e; phase3_restate) 2>&1 )"; rc=$?
[ "$rc" -eq 0 ] && pass "2: phase 3 completed (rc 0)" || fail "2: rc=$rc, expected 0"
grep -q '^   already completed: b1 on pod-b$' <<<"$out" && pass "2: prints already completed" \
  || fail "2: no 'already completed' line"
{ [ ! -e "$M/pod-b.log" ] || ! grep -q '^delete-cancel' "$M/pod-b.log"; } \
  && pass "2: no admin-API fallback" || fail "2: admin-API fallback ran"
[ "$(grep -c '^cancel b1$' "$M/pod-b.log")" = "2" ] && pass "2: cancelled again on the next pass" \
  || fail "2: b1 not cancelled twice"
grep -q 'kill' "$M/pod-b.log" && fail "2: escalated to kill" || pass "2: never escalated to kill"

# --- case 3: TERM -> exit 143 -> EXIT trap restores -------------------------
cat > "$M/inner.sh" <<INNER
set +e
NS=openddil; RELEASE=openddil
RESET_SCENARIO_SOURCE_ONLY=1
set --
. "$SCRIPT"
set +e
M="$M"
restate_json() { echo '[{"id":"c1"}]'; }
restate_count() { echo 1; }
kubectl() {
  case "\$*" in
    *"invocations cancel "*) : > "\$M/blocking"; command sleep 5 ;;
    "scale "*) echo "kubectl \$*" >> "\$M/term.scale.log" ;;
  esac
  return 0
}
DRY_RUN=false; SKIP_RESTATE=false; RESTATE_ZERO_GAP_S=0
RESTATE_PODS=(pod-c)
PRODUCER_DEPLOYS=(fake-producer); ORIG_REPLICAS[fake-producer]=1
SCALES_ARMED=true; SCALES_RESTORED=false
RESET_RUN=true; PHASES_DONE=("1 baseline" "pre-flight" "2 quiesce")
set -e
trap on_reset_exit EXIT
run_phase "3 restate" phase3_restate
INNER
rm -f "$M/blocking" "$M/term.scale.log"
bash "$M/inner.sh" > "$M/term.out" 2>&1 &
pid=$!
for _ in $(seq 1 100); do [ -e "$M/blocking" ] && break; command sleep 0.1; done
[ -e "$M/blocking" ] || fail "3: phase 3 never reached the blocking cancel"
kill -TERM "$pid" 2>/dev/null
wait "$pid"; rc=$?
[ "$rc" -eq 143 ] && pass "3: TERM - exit 143" || fail "3: rc=$rc, expected 143"
grep -q "scale deploy -n openddil fake-producer --replicas=1" "$M/term.scale.log" 2>/dev/null \
  && pass "3: scale-down restore ran after TERM" || fail "3: scale-down restore did not run after TERM"

echo
if [ "$FAIL" -eq 0 ]; then echo "test_reset_restate_backlog: ALL PASS"; exit 0; fi
echo "test_reset_restate_backlog: FAILED"; exit 1
