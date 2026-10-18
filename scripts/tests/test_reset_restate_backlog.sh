#!/usr/bin/env bash
# ===========================================================================
# test_reset_restate_backlog.sh — offline proof for three properties of
# restate_clear_pass / the signal handling in reset-scenario.sh, against the
# REAL functions (sourced via RESET_SCENARIO_SOURCE_ONLY, same seam as
# test_reset_restate_kill.sh):
#
#   1. A pod that reaches phase 3 above RESTATE_MAX_OPEN (default 300) with
#      no recorded confirmation (it grew after the pre-flight) halts the
#      reset (exit 2) BEFORE any cancel is issued, names the pod, the count
#      and --confirm-cancel-open, and the scale-down restores still run.
#   2. A cancel that fails with "No invocations found" (the invocation
#      completed between the list and the cancel) prints "already completed",
#      runs no admin-API fallback, and is not remembered as cancelled, so the
#      next sighting cancels again rather than escalating to kill.
#   3. TERM turns into a normal exit (143) and the EXIT trap restores the
#      scale-downs. NOTE: this runs bash as an ordinary process, not PID 1;
#      PID 1 semantics (TERM ignored without a handler) cannot be reproduced
#      here, so the case proves the handler -> EXIT trap -> restore chain.
#
# Cases a-f (after case 3) cover the bounded, confirmed bulk cancel: pre-flight
# halt with no flag and no tty (a), the flag (b), a stalled drain and its
# --kill round (c), growth past the bound (d), --dry-run (e), and at/below the
# limit (f).
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
  rm -f "$M/$pod".ids.* "$M/$pod.step" "$M/$pod.log" "$M/$pod.open_override" "$M/$pod.cancel_gone" "$M/$pod.bulk_mode"
  for ids in "$@"; do
    n=$((n + 1))
    : > "$M/$pod.ids.$n"
    if [ -n "$ids" ]; then printf '%s\n' $ids >> "$M/$pod.ids.$n"; fi
  done
}

restate_json() {
  local pod="$1" sql="$2" step f
  case "$sql" in
    *"group by 1,2,3"*)
      echo '[{"target_service_name":"svc-a","target_handler_name":"tick","status":"scheduled","n":900},{"target_service_name":"svc-b","target_handler_name":"run","status":"running","n":100}]' ;;
    *"group by service_name"*) echo '[{"service_name":"SvcA"}]' ;;
    *"group by 1"*)
      echo '[{"target_service_name":"svc-a","n":900},{"target_service_name":"svc-b","n":100}]' ;;
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
  local args="$*" pod id svc lim cur mode kl
  echo "$args" >> "$M/kubectl.all"
  case "$args" in
    "exec -n "*)
      pod="$4"
      case "$args" in
        *"invocations cancel "*"--limit "*)
          svc="${args##*invocations cancel }"; svc="${svc%% *}"
          lim="${args##*--limit }"; kl=0
          case "$args" in *"--kill"*) kl=1 ;; esac
          echo "bulk $svc limit=$lim kill=$kl" >> "$M/$pod.log"
          cur="$(cat "$M/$pod.open_override" 2>/dev/null || echo 0)"
          mode="$(cat "$M/$pod.bulk_mode" 2>/dev/null || echo drain)"
          case "$mode" in
            drain) cur=$((cur - lim)) ;;
            killonly) [ "$kl" = 1 ] && cur=$((cur - lim)) ;;
            grow) cur=$((cur + 4000)) ;;
            stuck) : ;;
          esac
          [ "$cur" -lt 0 ] && cur=0
          if [ "$cur" -le 300 ]; then rm -f "${M:?}/${pod:?}.open_override"; else echo "$cur" > "$M/$pod.open_override"; fi
          return 0 ;;
        *"state clear "*) echo "state-clear ${args##* }" >> "$M/$pod.log"; return 0 ;;
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

# --- case 1: over the limit with no recorded confirmation halts before any cancel
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
grep -q -- "--confirm-cancel-open" <<<"$out" && pass "1: names --confirm-cancel-open" || fail "1: --confirm-cancel-open not named"
grep -q -- "--skip-restate\|ephemeralOnUpgrade" <<<"$out" && fail "1: old remedy text still present" || pass "1: old remedy text gone"
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


# --- cases a-f: bounded, confirmed bulk cancel -------------------------------
# run_seq: the REAL run_reset_sequence and phase 3, every other phase stubbed
# to log its name. Runs in a subshell; the last line is RC=<exit code>.
run_seq() {
  (
    for f in phase1_baseline phase4_capture_pass phase2_quiesce phase3b_writer_census phase4_topics \
             phase5_aggregator phase6_stores phase7_electric phase8_zero phase9_restore_producers \
             verify_first_rollup phase10_subscription_liveness write_exercise_reset_record clear_declarations_banner; do
      eval "$f() { echo $f >> \"\$M/phases.log\"; return 0; }"
    done
    assert_consumers_declared() { return 0; }
    CAPTURED_TOPICS=()
    RESTATE_PODS=(pod-x)
    restate_have_tty() { echo tty-asked >> "$M/phases.log"; return 1; }
    run_reset_sequence
  ) 2>&1
  echo "RC=$?"
}
seq_rc() { sed -n 's/^RC=//p' <<<"$1" | tail -1; }
reset_seq() { rm -f "${M:?}/phases.log" "${M:?}/kubectl.all"; : > "$M/phases.log"; : > "$M/kubectl.all"; }
DRY_RUN=false; SKIP_RESTATE=false; RESTATE_BULK_BATCH=500; RESTATE_ZERO_GAP_S=0
RESTATE_CLEAR_MAX_PASSES=4; CONFIRM_CANCEL_OPEN=false

# (a) over the limit, no flag, no tty: halt before any mutation
seed_ids pod-x "x1" ""; echo 5000 > "$M/pod-x.open_override"; reset_seq
out="$(run_seq)"
[ "$(seq_rc "$out")" = 2 ] && pass "a: exit 2" || fail "a: rc=$(seq_rc "$out"), expected 2"
grep -q -- "--confirm-cancel-open" <<<"$out" && grep -q "pod-x" <<<"$out" && grep -q "5000" <<<"$out" \
  && pass "a: names the pods, counts and --confirm-cancel-open" || fail "a: halt text incomplete"
grep -q -- "exerciseControl.resetJob.extraArgs" <<<"$out" && pass "a: names the chart route" || fail "a: no chart route"
grep -q "phase2_quiesce\|phase4_topics\|phase6_stores" "$M/phases.log" && fail "a: a mutating phase ran" || pass "a: no phase 2+ ran"
[ ! -s "$M/kubectl.all" ] && pass "a: no kubectl command issued" || fail "a: kubectl was called"
grep -q "tty-asked" "$M/phases.log" && pass "a: tty was consulted before halting" || fail "a: tty never consulted"

# (a2) tty available: "yes" confirms; anything else halts, both before mutation
seed_ids pod-x "x1" ""; echo 2300 > "$M/pod-x.open_override"; reset_seq
out="$( ( restate_have_tty() { return 0; }; restate_read_tty() { printf 'no'; }; RESTATE_PODS=(pod-x); restate_open_preflight ) 2>&1; echo "RC=$?" )"
[ "$(seq_rc "$out")" = 2 ] && grep -q "type yes:" <<<"$out" && grep -q "Cancel up to 2300 open invocations across pod-x" <<<"$out" \
  && pass "a2: tty prompt, 'no' halts" || fail "a2: tty 'no' did not halt with the prompt"
out="$( ( restate_have_tty() { return 0; }; restate_read_tty() { printf 'yes'; }; RESTATE_PODS=(pod-x); restate_open_preflight; echo "N=${RESTATE_CONFIRMED_OPEN[pod-x]}" ) 2>&1; echo "RC=$?" )"
[ "$(seq_rc "$out")" = 0 ] && grep -q "N=2300" <<<"$out" && pass "a2: tty 'yes' confirms and records N_pod" || fail "a2: tty 'yes' did not confirm"

# (b) with the flag: bulk cancel per service, count drops over rounds, then per-id loop + state clear
seed_ids pod-x "x1" ""; echo 2300 > "$M/pod-x.open_override"; reset_seq; CONFIRM_CANCEL_OPEN=true
out="$(run_seq)"
[ "$(seq_rc "$out")" = 0 ] && pass "b: exit 0" || { fail "b: rc=$(seq_rc "$out")"; echo "$out" | tail -8; }
grep -q '^bulk svc-a limit=500 kill=0$' "$M/pod-x.log" && grep -q '^bulk svc-b limit=500 kill=0$' "$M/pod-x.log" \
  && pass "b: each service cancelled with --limit" || fail "b: per-service --limit calls missing"
grep -q "bulk cancel round 1 on pod-x: open 2300 -> 1300" <<<"$out" && grep -q "bulk cancel round 2 on pod-x: open 1300 -> " <<<"$out" \
  && pass "b: counts logged per round, dropping to the limit" || fail "b: round log lines wrong"
bl="$(grep -n '^bulk ' "$M/pod-x.log" | tail -1 | cut -d: -f1)"; cl="$(grep -n '^cancel x1$' "$M/pod-x.log" | head -1 | cut -d: -f1)"
{ [ -n "$cl" ] && [ -n "$bl" ] && [ "$cl" -gt "$bl" ]; } && pass "b: per-id cancel ran after the bulk rounds" || fail "b: per-id loop did not follow the drain"
grep -q '^state-clear SvcA$' "$M/pod-x.log" && pass "b: state clear ran" || fail "b: state clear did not run"
grep -q "phase4_topics" "$M/phases.log" && pass "b: later phases ran" || fail "b: later phases did not run"
grep -q "tty-asked" "$M/phases.log" && fail "b: asked the tty despite the flag" || pass "b: no tty prompt with the flag"
# the env var is the same switch: the script reads it into CONFIRM_CANCEL_OPEN at load
CONFIRM_CANCEL_OPEN=false
out="$(RESET_CONFIRM_CANCEL_OPEN=1 RESET_SCENARIO_SOURCE_ONLY=1 bash -c 's="$1"; set --; . "$s"; echo "C=$CONFIRM_CANCEL_OPEN"' _ "$SCRIPT" 2>&1)"
grep -q '^C=true$' <<<"$out" && pass "b: RESET_CONFIRM_CANCEL_OPEN=1 confirms" || fail "b: env var did not confirm"

# (c) no progress for two rounds: one --kill round, then halt with the table
CONFIRM_CANCEL_OPEN=true
seed_ids pod-x "x1" ""; echo 5000 > "$M/pod-x.open_override"; echo stuck > "$M/pod-x.bulk_mode"; reset_seq
out="$(run_seq)"
[ "$(seq_rc "$out")" = 2 ] && pass "c: stalled drain halts (exit 2)" || fail "c: rc=$(seq_rc "$out")"
[ "$(grep -c 'kill=0' "$M/pod-x.log")" = 4 ] && [ "$(grep -c 'kill=1' "$M/pod-x.log")" = 2 ] \
  && pass "c: two plain rounds, then exactly one --kill round" || fail "c: round pattern wrong: $(tr '\n' ' ' < "$M/pod-x.log")"
grep -q "even with --kill" <<<"$out" && grep -q "svc-a" <<<"$out" && grep -q "pod-x" <<<"$out" && grep -q "5000" <<<"$out" \
  && pass "c: halt names the pod, count and by-handler table" || fail "c: halt text incomplete"
grep -q "phase2_quiesce" "$M/phases.log" && grep -q "phase4_topics" "$M/phases.log" && fail "c: ran past the halt" || pass "c: phase 4 did not run"
# c2: stuck until --kill: the kill round drains and the run completes
seed_ids pod-x "x1" ""; echo 2300 > "$M/pod-x.open_override"; echo killonly > "$M/pod-x.bulk_mode"; reset_seq
out="$(run_seq)"
[ "$(seq_rc "$out")" = 0 ] && grep -q 'kill=1' "$M/pod-x.log" && pass "c2: --kill round unblocks the drain" || fail "c2: rc=$(seq_rc "$out")"

# (d) growth past 2*N_pod+1000: halt
seed_ids pod-x "x1" ""; echo 5000 > "$M/pod-x.open_override"; echo grow > "$M/pod-x.bulk_mode"; reset_seq
out="$(run_seq)"
[ "$(seq_rc "$out")" = 2 ] && grep -q "gaining open invocations" <<<"$out" && grep -q "svc-a" <<<"$out" \
  && pass "d: growth past the bound halts, table printed" || fail "d: rc=$(seq_rc "$out") / text missing"
[ "$(grep -c '^bulk ' "$M/pod-x.log")" -le 4 ] && pass "d: halted within the first rounds" || fail "d: kept cancelling"

# (e) --dry-run: plan printed, no cancel, no prompt, no halt
CONFIRM_CANCEL_OPEN=false
seed_ids pod-x "x1" ""; echo 5000 > "$M/pod-x.open_override"; reset_seq
out="$( ( DRY_RUN=true; RESTATE_PODS=(pod-x); restate_have_tty() { echo tty-asked >> "$M/phases.log"; return 0; }; restate_open_preflight ) 2>&1; echo "RC=$?" )"
[ "$(seq_rc "$out")" = 0 ] && grep -q "dry-run.*would bulk-cancel up to 5000" <<<"$out" && grep -q "svc-a" <<<"$out" \
  && pass "e: dry-run prints the table and plan, exit 0" || fail "e: dry-run output wrong"
{ [ ! -s "$M/kubectl.all" ] && ! grep -q tty-asked "$M/phases.log"; } && pass "e: no cancel, no prompt" || fail "e: cancel or prompt under dry-run"

# (f) at or below the limit: unchanged
seed_ids pod-x "x1" ""; echo 300 > "$M/pod-x.open_override"; reset_seq
out="$( ( RESTATE_PODS=(pod-x); restate_have_tty() { echo tty-asked >> "$M/phases.log"; return 0; }; restate_open_preflight ) 2>&1; echo "RC=$?" )"
[ "$(seq_rc "$out")" = 0 ] && [ "$(wc -l <<<"$out")" = 1 ] && ! grep -q tty-asked "$M/phases.log" \
  && pass "f: exactly 300 open - pre-flight silent, no prompt" || fail "f: pre-flight not silent at the limit"
seed_ids pod-x "x1 x2" ""; reset_seq
out="$(run_seq)"
[ "$(seq_rc "$out")" = 0 ] && pass "f: small backlog completes" || { fail "f: rc=$(seq_rc "$out")"; echo "$out" | tail -8; }
{ ! grep -q '^bulk ' "$M/pod-x.log"; } && ! grep -q "tty-asked" "$M/phases.log" && grep -q '^cancel x1$' "$M/pod-x.log" \
  && pass "f: no bulk call, no prompt, per-id loop as before" || fail "f: behaviour changed at or below the limit"

echo
if [ "$FAIL" -eq 0 ]; then echo "test_reset_restate_backlog: ALL PASS"; exit 0; fi
echo "test_reset_restate_backlog: FAILED"; exit 1
