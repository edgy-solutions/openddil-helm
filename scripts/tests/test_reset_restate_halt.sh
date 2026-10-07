#!/usr/bin/env bash
# ===========================================================================
# test_reset_restate_halt.sh — offline proof for two properties of
# reset-scenario.sh, against its REAL functions (sourced the same way as
# test_reset_ownership.sh; see that file's header for the SOURCE_ONLY seam):
#
#   1. Phase 3 cancels, clears and RE-READS each Restate instance until two
#      reads agree at zero, so an id that turns over mid-read (a timer that
#      fires and re-arms under a new id) is caught by the next pass, not
#      refused-and-skipped.
#   2. Any safety refusal HALTS the whole reset: no later phase runs, the
#      exit trap names where it stopped, what stays applied, what did not
#      run and what the refusal measured, and scaled-down workloads are
#      restored.
#
# Restate is replaced by a small file-backed model ($M/<pod>.timers,
# $M/<pod>.state) behind the script's own contact points: restate_json,
# restate_count and kubectl. The model's one rule is the measured one
# (asset_logistics.py:477): a timer whose object has no state fires and
# writes the state back.
#
# RED CHECK: SCRIPT=<path> runs this against another copy of the script. Run
# against the pre-fix script (git show 36b3ff3:scripts/reset-scenario.sh) it
# must exit 1; against the fix it must exit 0.
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
seed() {  # seed POD NKEYS
  local pod="$1" n="$2" i
  : > "$M/$pod.timers"; : > "$M/$pod.state"; rm -f "$M/$pod.race" "$M/$pod.sticky" "$M/$pod.late"
  for i in $(seq 1 "$n"); do
    echo "k$i inv-$pod-$i" >> "$M/$pod.timers"
    printf 'AssetLogistics k%s r1\nAssetLogistics k%s r2\nAssetCM k%s r1\n' "$i" "$i" "$i" >> "$M/$pod.state"
  done
}

tick() {  # a timer whose object has no AssetLogistics state fires and writes it back
  local pod="$1" key id
  while read -r key id; do
    [ -z "$key" ] && continue
    grep -q "^AssetLogistics $key " "$M/$pod.state" \
      || printf 'AssetLogistics %s r1\nAssetLogistics %s r2\n' "$key" "$key" >> "$M/$pod.state"
  done < "$M/$pod.timers"
}

model_counts() {  # -> "keys rows scheduled", after a tick
  local pod="$1"
  tick "$pod"
  echo "$(awk '{print $2}' "$M/$pod.state" | sort -u | grep -c .) $(grep -c . "$M/$pod.state") $(grep -c . "$M/$pod.timers")"
}

restate_json() {
  local pod="$1" sql="$2" r
  case "$sql" in
    *"select id from sys_invocation"*)
      r="$(cat "$M/$pod.race" 2>/dev/null || echo 0)"
      if [ "$r" -gt 0 ] && [ -s "$M/$pod.timers" ]; then
        # The race measured on 2026-10-01: the list misses the one timer that
        # is firing, and that timer re-arms under a new id before the count.
        echo $((r - 1)) > "$M/$pod.race"
        head -n -1 "$M/$pod.timers" | awk 'BEGIN{printf "["} {printf "%s{\"id\":\"%s\"}", (NR>1?",":""), $2} END{print "]"}'
        tail -1 "$M/$pod.timers" | awk '{print $1, $2 "-rearmed"}' > "$M/$pod.last"
        head -n -1 "$M/$pod.timers" > "$M/$pod.t2"; cat "$M/$pod.last" >> "$M/$pod.t2"; mv "$M/$pod.t2" "$M/$pod.timers"
      else
        awk 'BEGIN{printf "["} {printf "%s{\"id\":\"%s\"}", (NR>1?",":""), $2} END{print "]"}' "$M/$pod.timers"
      fi
      ;;
    *"select service_name, count(distinct service_key)"*)
      awk '{print $1, $2}' "$M/$pod.state" | sort -u | awk '{c[$1]++} END{printf "["; s=""; for (k in c) {printf "%s{\"service_name\":\"%s\",\"n\":%d}", s, k, c[k]; s=","} print "]"}'
      ;;
    *) echo "[]" ;;
  esac
}

restate_count() {
  local pod="$1" sql="$2"
  tick "$pod"
  case "$sql" in
    *"count(distinct service_name)"*) awk '{print $1}' "$M/$pod.state" | sort -u | grep -c . ;;
    *"count(distinct service_key)"*)  awk '{print $2}' "$M/$pod.state" | sort -u | grep -c . ;;
    *"count(*) as n from state"*)     grep -c . "$M/$pod.state" ;;
    *"sys_invocation"*)               grep -c . "$M/$pod.timers" ;;
    *) echo 0 ;;
  esac
}

cancel_id() {
  local pod="$1" id="$2" key
  key="$(awk -v id="$id" '$2==id{print $1}' "$M/$pod.timers")"
  [ -z "$key" ] && return 1
  [ "$(cat "$M/$pod.sticky" 2>/dev/null)" = "$key" ] && return 1
  grep -v " $id\$" "$M/$pod.timers" > "$M/$pod.t2"; mv "$M/$pod.t2" "$M/$pod.timers"
}

kubectl() {
  local args="$*" pod id svc
  case "$args" in
    "exec -n "*)
      pod="$4"
      case "$args" in
        *"invocations cancel "*) id="${args##* }"; cancel_id "$pod" "$id" ;;
        *"DELETE"*"/invocations/"*) id="${args##*/invocations/}"; id="${id%%\?*}"; cancel_id "$pod" "$id" ;;
        *"state clear "*)
          svc="${args#*state clear }"; svc="${svc%% *}"
          grep -v "^$svc " "$M/$pod.state" > "$M/$pod.t2"; mv "$M/$pod.t2" "$M/$pod.state" ;;
        *) return 0 ;;
      esac
      ;;
    "scale "*) echo "kubectl $args" >> "$M/scale.log" ;;
    *) return 0 ;;
  esac
}

# Time passing. A pod with a .late key gains a timer that was invisible to
# every read so far (an invocation in flight), then fires.
sleep() {
  local f pod key
  for f in "$M"/*.late; do
    [ -e "$f" ] || continue
    pod="$(basename "$f" .late)"; key="$(cat "$f")"; rm -f "$f"
    echo "$key inv-$pod-$key-late" >> "$M/$pod.timers"
    tick "$pod"
  done
}

# The pre-fix script has no run_phase; give it the obvious stand-in so a red
# run measures its behaviour, not a missing name.
type run_phase >/dev/null 2>&1 || run_phase() { "$2"; }

DRY_RUN=false
SKIP_RESTATE=false
RESTATE_CLEAR_MAX_PASSES=3

# --- case A: the 2026-10-01 race. pod-a's list misses one timer that re-arms
# under a new id; pod-b reads cleanly. Both must end at zero, no halt.
seed pod-a 8; echo 1 > "$M/pod-a.race"
seed pod-b 4
RESTATE_PODS=(pod-a pod-b)
out="$( (set -e; phase3_restate) 2>&1 )"; rc=$?
sleep
a="$(model_counts pod-a)"; b="$(model_counts pod-b)"
[ "$rc" -eq 0 ] && pass "A: race — phase 3 completed (rc 0)" || fail "A: race — phase 3 rc=$rc, expected 0"
[ "$a" = "0 0 0" ] && pass "A: race — pod-a at zero" || fail "A: race — pod-a residue (keys rows scheduled) $a"
[ "$b" = "0 0 0" ] && pass "A: race — pod-b at zero" || fail "A: race — pod-b residue $b"
if grep -q 'pod-a: clear after [2-9] pass' <<<"$out"; then pass "A: race — pod-a needed a second pass"
else fail "A: race — no 'pod-a: clear after N>=2 passes' line"; fi

# --- case A2: two reads, not one. pod-c reads zero once, then an in-flight
# timer appears; a single zero read would have stopped there.
seed pod-c 3; echo k9 > "$M/pod-c.late"
RESTATE_PODS=(pod-c)
out="$( (set -e; phase3_restate) 2>&1 )"; rc=$?
sleep
c="$(model_counts pod-c)"
[ "$rc" -eq 0 ] && [ "$c" = "0 0 0" ] && pass "A2: late timer — pod-c at zero after the second read" \
  || fail "A2: late timer — rc=$rc, pod-c residue $c"

# --- case B: never converges (a timer that cannot be cancelled). The whole
# reset must halt in phase 3, name the pod and residue, run nothing later,
# and restore the scaled-down producer.
seed pod-d 2; echo k1 > "$M/pod-d.sticky"
seed pod-e 2
RESTATE_PODS=(pod-d pod-e)
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
e="$(model_counts pod-e)"
[ "$rc" -eq 2 ] && pass "B: stuck timer — exit 2" || fail "B: stuck timer — exit $rc, expected 2"
grep -q "RESET HALTED" <<<"$out" && pass "B: stuck timer — RESET HALTED block" || fail "B: stuck timer — no RESET HALTED block"
grep -q "halted in: 3 restate" <<<"$out" && pass "B: names the phase" || fail "B: phase not named"
grep -q "pod-d residue (keys rows scheduled open): 1 2 1 1" <<<"$out" && pass "B: names pod-d and its residue" \
  || fail "B: pod-d residue not named"
grep -q "not reached: pod-e" <<<"$out" && pass "B: names pod-e as not reached" || fail "B: pod-e not named as not reached"
grep -q "not run:   3b writer census 4 topics 5 aggregator 6 stores 7 electric 8 zero assertion 9 restore" <<<"$out" \
  && pass "B: names the phases not run" || fail "B: phases not run not named"
grep -q "PHASE-4-RAN" <<<"$out" && fail "B: a later phase ran after the refusal" || pass "B: no later phase ran"
[ "$e" != "0 0 0" ] && pass "B: pod-e untouched ($e)" || fail "B: pod-e was cleared after the halt"
grep -q "scale deploy -n openddil fake-producer --replicas=1" "$M/scale.log" \
  && pass "B: scaled-down producer restored" || fail "B: producer not restored"

# --- case C: a refusal outside phase 3 (an EXCLUDED_TABLES delete) halts the
# same way.
: > "$M/scale.log"
out="$( (
  set -e
  PRODUCER_DEPLOYS=(fake-producer); ORIG_REPLICAS[fake-producer]=1
  SCALES_ARMED=true; SCALES_RESTORED=false
  RESET_RUN=true
  PHASES_DONE=("1 baseline" "pre-flight" "2 quiesce" "3 restate" "4 topics" "5 aggregator")
  type on_reset_exit >/dev/null 2>&1 && trap on_reset_exit EXIT
  stores_with_refusal() { delete_table pg-0 "${EXCLUDED_TABLES[0]}"; echo "AFTER-REFUSAL"; }
  run_phase "6 stores" stores_with_refusal
  echo "PHASE-7-RAN"
) 2>&1 )"; rc=$?
[ "$rc" -eq 2 ] && pass "C: excluded table — exit 2" || fail "C: excluded table — exit $rc, expected 2"
grep -q "halted in: 6 stores" <<<"$out" && pass "C: names the phase" || fail "C: phase not named"
grep -q "${EXCLUDED_TABLES[0]} on pg-0 untouched" <<<"$out" && pass "C: names the table" || fail "C: table not named"
grep -q "completed: 1 baseline pre-flight 2 quiesce 3 restate 4 topics 5 aggregator" <<<"$out" \
  && pass "C: names what stays applied" || fail "C: completed phases not named"
grep -q "AFTER-REFUSAL\|PHASE-7-RAN" <<<"$out" && fail "C: execution continued past the refusal" || pass "C: nothing ran past the refusal"
grep -q "fake-producer --replicas=1" "$M/scale.log" && pass "C: producer restored" || fail "C: producer not restored"

# --- case D: a phase that stops on a bare `return 1` is a halt too.
out="$( (
  set -e
  RESET_RUN=true; PHASES_DONE=("1 baseline")
  type on_reset_exit >/dev/null 2>&1 && trap on_reset_exit EXIT
  failing_phase() { echo "ERROR: simulated" >&2; return 1; }
  run_phase "2 quiesce" failing_phase
  echo "PHASE-3-RAN"
) 2>&1 )"; rc=$?
{ [ "$rc" -ne 0 ] && grep -q "RESET HALTED" <<<"$out" && grep -q "halted in: 2 quiesce" <<<"$out" \
    && ! grep -q "PHASE-3-RAN" <<<"$out"; } \
  && pass "D: bare return 1 reported as a halt" || fail "D: bare return 1 not reported as a halt (rc=$rc)"

# --- case E: a completed run whose phase 8 failed is NOT a halt.
out="$( (
  RESET_RUN=true; SCALES_ARMED=true; SCALES_RESTORED=true
  type on_reset_exit >/dev/null 2>&1 && trap on_reset_exit EXIT
  RUN_COMPLETED=true
  exit 1
) 2>&1 )"; rc=$?
{ [ "$rc" -eq 1 ] && ! grep -q "RESET HALTED" <<<"$out"; } \
  && pass "E: completed run with phase-8 FAIL exits 1, no halt block" || fail "E: rc=$rc or a halt block on a completed run"

echo
if [ "$FAIL" -eq 0 ]; then echo "test_reset_restate_halt: ALL PASS"; exit 0; fi
echo "test_reset_restate_halt: FAILED"; exit 1
