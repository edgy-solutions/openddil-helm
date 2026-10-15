#!/usr/bin/env bash
# ===========================================================================
# test-effector-consumer-parse.sh — offline proof of
# check-effector-consumer.sh's `parse_group_describe` against CAPTURED rpk
# text, run through the REAL function (sourced from the real script), not a
# reimplementation of its awk.
# ===========================================================================
# The probe refuses to turn a garbled read into a confident zero (see that
# script's own header). This test is the proof: fixtures/ holds synthetic
# `rpk group describe` output for an Empty group, a Stable group with lag
# above zero, a Stable group with lag back at zero, and a garbled/unreadable
# read -- all synthetic group, topic and host names only. The script is
# sourced with OPENDDIL_EFFECTOR_CONSUMER_SOURCE_ONLY=1, the same toggle
# reset-scenario.sh's own offline test uses, so this never runs the cluster
# guard or the probe's main loop -- only loads the function definitions.
# ===========================================================================
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROBE="$HERE/../check-effector-consumer.sh"
FIXTURES="$HERE/fixtures"

export OPENDDIL_EFFECTOR_CONSUMER_SOURCE_ONLY=1
# shellcheck source=../check-effector-consumer.sh
. "$PROBE"

fail=0

check_parses() {
  local label="$1" fixture="$2" want_state="$3" want_members="$4" want_lag="$5"
  local got rc
  got="$(parse_group_describe < "$FIXTURES/$fixture")"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "FAIL: ($label) expected a successful parse of $fixture, got rc=$rc"
    fail=1
    return
  fi
  local want="$want_state"$'\t'"$want_members"$'\t'"$want_lag"
  if [ "$got" != "$want" ]; then
    echo "FAIL: ($label) parse_group_describe($fixture) = '$got', want '$want'"
    fail=1
  else
    echo "PASS: ($label) parse_group_describe($fixture) = '$got'"
  fi
}

check_rejects() {
  local label="$1" fixture="$2"
  local got rc
  got="$(parse_group_describe < "$FIXTURES/$fixture")"
  rc=$?
  if [ "$rc" -eq 0 ]; then
    echo "FAIL: ($label) expected $fixture to be REJECTED (rc!=0), got rc=0 output='$got'"
    fail=1
  else
    echo "PASS: ($label) parse_group_describe($fixture) correctly rejected (rc=$rc), no fabricated zero"
  fi
}

# (1) Empty group: 0 members, 0 lag -- a legitimate NOT_ALIVE reading, not a
# parse failure.
check_parses "empty-group" "rpk-group-describe-empty.txt" "Empty" "0" "0"

# (2) Stable group, lag above zero -- a legitimate in-flight reading.
check_parses "lag-above-zero" "rpk-group-describe-lag.txt" "Stable" "1" "57"

# (3) Stable group, lag back at zero -- the other half of the ALIVE check
# (lag==0 at the second read).
check_parses "stable-zero-lag" "rpk-group-describe-stable.txt" "Stable" "1" "0"

# (4) Garbled/unreadable read (a connection error, no STATE/MEMBERS/TOTAL-LAG
# lines at all) -- this is what upstream's read_group() turns into a
# READ-FAILED and, at the top level, exit 3. It must never parse as a
# confident "0 members, 0 lag".
check_rejects "garbled-read" "rpk-group-describe-garbled.txt"

# ---------------------------------------------------------------------------
# --producer: run the real probe (a subprocess, so the SOURCE_ONLY load above
# is not in play) against a stub kubectl that serves the captured fixtures
# and records which group and topic it was asked about.
# ---------------------------------------------------------------------------
STUB="$(mktemp -d)"
trap 'rm -rf "$STUB"' EXIT
cat > "$STUB/kubectl" <<'KUBE'
#!/usr/bin/env bash
case "${1:-}" in
  config) echo synthetic-offline-ctx; exit 0 ;;
  -n)
    echo "$*" >> "$STUB_LOG"
    case "$*" in
      *"group describe"*) cat "$FIXTURES/rpk-group-describe-stable.txt" ;;
      *"topic describe"*) cat "$FIXTURES/rpk-topic-describe-good.txt" ;;
    esac
    exit 0 ;;
esac
exit 0
KUBE
chmod +x "$STUB/kubectl"

run_probe() {  # run_probe RESULT_FILE args...
  local res="$1"; shift
  : > "$STUB/log"
  env -u OPENDDIL_EFFECTOR_CONSUMER_SOURCE_ONLY PATH="$STUB:$PATH" \
    OPENDDIL_EXPECT_CONTEXT=synthetic-offline-ctx FIXTURES="$FIXTURES" \
    STUB_LOG="$STUB/log" OPENDDIL_EFFECTOR_CONSUMER_RESULT="$res" \
    bash "$PROBE" "$@" >"$STUB/out" 2>&1
}

if run_probe "$STUB/m.result" --producer munition-track --tier edge-01 0 \
   && grep -qx 'group=tier-projector-munition-track-edge-01' "$STUB/m.result" \
   && grep -q 'group describe tier-projector-munition-track-edge-01' "$STUB/log" \
   && grep -q 'topic describe munition-tracks' "$STUB/log"; then
  echo "PASS: --producer munition-track reads its own group and munition-tracks"
else
  echo "FAIL: --producer munition-track group/topic wrong: $(cat "$STUB/log")"; fail=1
fi

if run_probe "$STUB/e.result" 0 \
   && grep -qx 'group=projector-effector-launch' "$STUB/e.result" \
   && grep -q 'topic describe effector-events' "$STUB/log"; then
  echo "PASS: default producer is still effector-launch on effector-events"
else
  echo "FAIL: default producer changed: $(cat "$STUB/log")"; fail=1
fi

run_probe "$STUB/bad.result" --producer bogus 0; rc=$?
if [ "$rc" -ne 0 ] && grep -q 'usage:' "$STUB/out" && [ ! -e "$STUB/bad.result" ]; then
  echo "PASS: bad --producer exits non-zero with a usage line and publishes nothing"
else
  echo "FAIL: bad --producer rc=$rc"; fail=1
fi

if [ "$fail" -ne 0 ]; then
  echo "test-effector-consumer-parse.sh: FAIL"
  exit 1
fi
echo "test-effector-consumer-parse.sh: ALL PASS"
exit 0
