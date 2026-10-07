#!/usr/bin/env bash
# ===========================================================================
# test_reset_policytrim.sh — offline proof for phase 4's policy-trim bucket
# and for phase 10 (subscription liveness), against
# reset-scenario.sh's REAL functions (sourced the same way
# test_reset_restate_halt.sh and test_reset_ownership.sh do; see either
# file's header for the SOURCE_ONLY seam).
#
# Properties proved:
#   1. A pure-compact topic is emptied by alter(compact,delete) -> trim ->
#      alter(restore), in exactly that order, and `rpk topic delete` /
#      `rpk topic create` are never invoked for it.
#   2. A failure at the trim step (policy already widened) HALTS the whole
#      run, names the exact command to restore cleanup.policy by hand, and
#      runs nothing after it.
#   3. A restore that reports success but does not actually take effect is
#      caught by assert_topic_matches_capture and HALTS the run.
#   4. Phase 10: check-subscription-liveness.sh exit 1 sets OVERALL_FAIL=1
#      (and names the stalled subscription); exit 0 leaves OVERALL_FAIL
#      unchanged; a missing script sets OVERALL_FAIL=1 too — never a skip.
#
# `rpk` itself is never invoked here; every `rpk topic ...` call reaches
# this file's `kubectl` stub (the real script always runs rpk through
# `kubectl exec ... -- rpk ...`), which models exactly one broker holding
# one partition per topic, in files under $M.
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

# --- the broker model -------------------------------------------------------
# $M/<topic>.policy        current cleanup.policy
# $M/<topic>.p0.logstart   partition 0 log-start offset
# $M/<topic>.p0.hw         partition 0 high watermark
# $M/<topic>.fail_trim     "1" -> trim-prefix on this topic always fails
# $M/<topic>.restore_noop  "1" -> an alter-config back to the captured value
#                          reports success but does not change $M/<topic>.policy
# $M/calls.log             every rpk subcommand this run issued, in order
seed_topic() {  # seed_topic TOPIC POLICY LOGSTART HW
  local t="$1"
  echo "$2" > "$M/$t.policy"
  echo "$3" > "$M/$t.p0.logstart"
  echo "$4" > "$M/$t.p0.hw"
  rm -f "$M/$t.fail_trim" "$M/$t.restore_noop"
}

kubectl() {
  local args=("$@") i n=$# action="" topic="" val off
  for ((i = 0; i < n; i++)); do
    if [ "${args[$i]:-}" = "rpk" ] && [ "${args[$((i + 1))]:-}" = "topic" ]; then
      action="${args[$((i + 2))]:-}"
      topic="${args[$((i + 3))]:-}"
      break
    fi
  done
  echo "${args[*]}" >> "$M/calls.log"
  case "$action" in
    list)
      printf 'NAME\n'
      local t; for t in "${ALL_TOPICS[@]}"; do printf '%s\n' "$t"; done
      ;;
    describe)
      # The container selector "-c redpanda" is present on EVERY call, so the
      # rpk-level -c/-p flag (when present) is only ever the LAST argument.
      if [ "${args[$((n - 1))]}" = "-c" ]; then
        printf 'KEY             VALUE                  SOURCE\n'
        printf 'cleanup.policy  %s  DYNAMIC_TOPIC_CONFIG\n' "$(cat "$M/$topic.policy")"
      elif [ "${args[$((n - 1))]}" = "-p" ]; then
        printf 'PARTITION  LEADER  EPOCH  REPLICAS  LOG-START-OFFSET  HIGH-WATERMARK\n'
        printf '0          1       1      [1]       %s                %s\n' \
          "$(cat "$M/$topic.p0.logstart")" "$(cat "$M/$topic.p0.hw")"
      else
        printf 'SUMMARY\nNAME        %s\nPARTITIONS  1\nREPLICAS    1\n' "$topic"
      fi
      ;;
    alter-config)
      val="${args[*]}"; val="${val#*cleanup.policy=}"; val="${val%% *}"
      if [ "$val" = "compact,delete" ]; then
        echo "compact,delete" > "$M/$topic.policy"
      elif [ "$(cat "$M/$topic.restore_noop" 2>/dev/null)" = "1" ]; then
        : # simulate a restore that reports success but does not apply
      else
        echo "$val" > "$M/$topic.policy"
      fi
      ;;
    trim-prefix)
      if [ "$(cat "$M/$topic.fail_trim" 2>/dev/null)" = "1" ]; then
        return 1
      fi
      off="${args[*]}"; off="${off#*--offset }"; off="${off%% *}"
      echo "$off" > "$M/$topic.p0.logstart"
      ;;
    delete | create) : ;; # logged above; asserted to never appear
  esac
  return 0
}

DRY_RUN=false
SKIP_TOPICS=false
RED_CHECK_TOPIC_CONFIG=false
RPK_CMD_TIMEOUT=60
REDPANDA_PODS=(pod-a)

# --- case 1: order, and no delete/create ------------------------------------
: > "$M/calls.log"
seed_topic demo-changelog compact 0 5
ALL_TOPICS=(demo-changelog)
out="$( (set -e; phase4_capture_pass; phase4_topics) 2>&1 )"; rc=$?
[ "$rc" -eq 0 ] && pass "1: policy-trim completed (rc 0)" || fail "1: rc=$rc, expected 0"

seq="$(awk '{
  if ($0 ~ /alter-config/ && $0 ~ /cleanup\.policy=compact,delete/) print "widen"
  else if ($0 ~ /trim-prefix/) print "trim"
  else if ($0 ~ /alter-config/) print "restore"
}' "$M/calls.log")"
[ "$seq" = "$(printf 'widen\ntrim\nrestore')" ] \
  && pass "1: alter(compact,delete) -> trim -> alter(restore), in that order" \
  || fail "1: wrong order/shape, saw: $(echo "$seq" | tr '\n' ' ')"
grep -q "topic delete " "$M/calls.log" && fail "1: rpk topic delete was called" || pass "1: rpk topic delete never called"
grep -q "topic create " "$M/calls.log" && fail "1: rpk topic create was called" || pass "1: rpk topic create never called"
[ "$(cat "$M/demo-changelog.policy")" = "compact" ] && pass "1: cleanup.policy restored to compact" \
  || fail "1: cleanup.policy ended as $(cat "$M/demo-changelog.policy"), expected compact"
[ "$(cat "$M/demo-changelog.p0.logstart")" = "5" ] && pass "1: log-start trimmed to the watermark" \
  || fail "1: log-start ended as $(cat "$M/demo-changelog.p0.logstart"), expected 5"

# --- case 2: trim step fails -> halt, restore command named, nothing after --
: > "$M/calls.log"
seed_topic demo-changelog compact 0 5
echo 1 > "$M/demo-changelog.fail_trim"
ALL_TOPICS=(demo-changelog)
out="$( (set -e; phase4_capture_pass; phase4_topics; echo AFTER-PHASE4) 2>&1 )"; rc=$?
[ "$rc" -ne 0 ] && pass "2: trim failure halts (rc=$rc != 0)" || fail "2: trim failure did not halt"
grep -q "PHASE 4 FAILED" <<<"$out" && pass "2: PHASE 4 FAILED reported" || fail "2: no PHASE 4 FAILED line"
grep -q "restore it by hand: kubectl exec -n openddil pod-a -c redpanda -- rpk topic alter-config demo-changelog --set cleanup.policy=compact --no-confirm" <<<"$out" \
  && pass "2: exact restore command named" || fail "2: restore command not named as expected"
grep -q "AFTER-PHASE4" <<<"$out" && fail "2: something ran after the halt" || pass "2: nothing ran after the halt"
[ "$(cat "$M/demo-changelog.policy")" = "compact,delete" ] && pass "2: cleanup.policy left widened (as the halt message says)" \
  || fail "2: cleanup.policy unexpectedly changed to $(cat "$M/demo-changelog.policy")"

# --- case 3: restore reports success but does not apply -> verify mismatch
# halts -------------------------------------------------------------------
: > "$M/calls.log"
seed_topic demo-changelog compact 0 5
echo 1 > "$M/demo-changelog.restore_noop"
ALL_TOPICS=(demo-changelog)
out="$( (set -e; phase4_capture_pass; phase4_topics; echo AFTER-PHASE4) 2>&1 )"; rc=$?
[ "$rc" -ne 0 ] && pass "3: restore-verify mismatch halts (rc=$rc != 0)" || fail "3: mismatch did not halt"
grep -q "did not match its capture" <<<"$out" && pass "3: capture-mismatch reason reported" \
  || fail "3: no capture-mismatch reason in output"
grep -q "AFTER-PHASE4" <<<"$out" && fail "3: something ran after the halt" || pass "3: nothing ran after the halt"

# --- case 4: phase 10 exit-code mapping -------------------------------------
cat > "$M/wrapper.sh" <<'WRAPEOF'
#!/usr/bin/env bash
set -u
NS=openddil RELEASE=openddil RESET_SCENARIO_SOURCE_ONLY=1
export NS RELEASE RESET_SCENARIO_SOURCE_ONLY
script_path="$1"
set --
. "$script_path"
set +e
DRY_RUN=false
OVERALL_FAIL=0
PHASE9_DONE_AT="2026-10-06T00:00:00Z"
RESET_LIVENESS_WAIT=1
phase10_subscription_liveness
echo "WRAPPER: OVERALL_FAIL=$OVERALL_FAIL"
WRAPEOF
chmod +x "$M/wrapper.sh"

cat > "$M/check-subscription-liveness.sh" <<'FAKEEOF'
#!/usr/bin/env bash
if [ "${FAKE_LIVENESS_EXIT:-0}" = "1" ]; then
  echo "STALLED pod-a sub-1 some-topic -> SomeHandler input=yes invocations=0"
fi
exit "${FAKE_LIVENESS_EXIT:-0}"
FAKEEOF
chmod +x "$M/check-subscription-liveness.sh"

out="$(bash "$M/wrapper.sh" "$SCRIPT" 2>&1)"
grep -q "OVERALL_FAIL=0" <<<"$out" && pass "4a: liveness exit 0 leaves OVERALL_FAIL unchanged" \
  || fail "4a: OVERALL_FAIL changed on a passing liveness check"

out="$(FAKE_LIVENESS_EXIT=1 bash "$M/wrapper.sh" "$SCRIPT" 2>&1)"
grep -q "OVERALL_FAIL=1" <<<"$out" && pass "4b: liveness exit 1 sets OVERALL_FAIL=1" \
  || fail "4b: OVERALL_FAIL not set on a failing liveness check"
grep -q "STALLED pod-a sub-1" <<<"$out" && pass "4b: stalled subscription named in the output" \
  || fail "4b: stalled subscription not named"

rm -f "$M/check-subscription-liveness.sh"
out="$(bash "$M/wrapper.sh" "$SCRIPT" 2>&1)"
grep -q "OVERALL_FAIL=1" <<<"$out" && pass "4c: a missing check script sets OVERALL_FAIL=1" \
  || fail "4c: a missing check script was silently skipped"

echo
if [ "$FAIL" -eq 0 ]; then echo "test_reset_policytrim: ALL PASS"; exit 0; fi
echo "test_reset_policytrim: FAILED"; exit 1
