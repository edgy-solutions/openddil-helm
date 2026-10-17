#!/usr/bin/env bash
# ===========================================================================
# test_reset_first_rollup.sh -- offline proof for phase 11 of reset-scenario.sh
# (verify_first_rollup), against the REAL function and decoder. kubectl, the
# partition reader and sleep are stubbed; the protobuf values are built by hand
# below (field 1 string, field 6 varint, field 7 nested seconds varint).
#
# Cases:
#   I. one record carrying asset_count 1                  -> MET.
#   J. one sweep of two class records (1 + 1) on two partitions, plus a later
#      sweep's record (5)                                  -> asset_count=2 ... MISS.
#   K. no advance by the deadline                          -> "not measured".
#   L. quick mode                                          -> phase 11 never runs.
#   M. asset_count absent on the wire (proto3 zero)        -> asset_count=0 ... MISS.
#   N. the reset record carries the measured first_rollup.
# In I, J, K and M the phase never changes OVERALL_FAIL and returns 0.
# Flips: SCRIPT=<mutated copy> (decoder reads field 2; MISS routed via report).
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

# The reset-runner image has python3; a Windows dev shell may only have py.
if ! command -v python3 >/dev/null 2>&1; then
  python3() { py -3 "$@"; }
fi

# --- hand-built protobuf ------------------------------------------------------
# rec SECS COUNT -> base64 of: 0a 01 72 (region_id "r"), [30 COUNT] (asset_count,
# omitted when 0), 3a 03 08 <secs varint, two bytes> (observed_at.seconds).
rec() {
  local secs="$1" cnt="$2" hex
  hex="0a0172"
  [ "$cnt" -ne 0 ] && hex+="$(printf '30%02x' "$cnt")"
  hex+="$(printf '3a0408%02x%02x' $(( (secs & 0x7f) | 0x80 )) $(( secs >> 7 )))"
  # inner message is 08 + 2 varint bytes = 3 bytes
  hex="${hex/3a04/3a03}"
  printf "$(printf '%s' "$hex" | sed 's/../\\x&/g')" | base64 -w0
  echo
}

# --- stubs ------------------------------------------------------------------
BPOD="openddil-redpanda-region-east-0"
HW0=5 HW1=5          # current hw per partition (marks are 5 and 5)
RECS0="" RECS1=""    # base64 lines served for partition 0 / 1
sleep() { :; }
topic_partitions() { echo "0 5 $HW0"; echo "1 5 $HW1"; }
kubectl() {
  local p
  case " $* " in *" -p 0 "*) p=0 ;; *) p=1 ;; esac
  if [ "$p" = 0 ]; then printf '%s' "$RECS0"; else printf '%s' "$RECS1"; fi
}

# run_case -> out, RC, OF  (marks are 5 and 5 on the one broker)
run_case() {
  AGG_EMPTY_HW=(); AGG_EMPTY_HW["$BPOD|0"]=5; AGG_EMPTY_HW["$BPOD|1"]=5
  FIRST_ROLLUP_COUNT=""; FIRST_ROLLUP_AT=""; FIRST_ROLLUP_VERDICT="not measured"; FIRST_ROLLUP_BROKER=""
  OVERALL_FAIL=0; DRY_RUN=false; PHASE9_DONE_AT=""
  out="$(verify_first_rollup 2>&1; echo "RC=$?"; echo "OF=$OVERALL_FAIL")"
  RC="$(printf '%s\n' "$out" | sed -n 's/^RC=//p')"
  OF="$(printf '%s\n' "$out" | sed -n 's/^OF=//p')"
  # run once more in this shell so the globals (record fields) are visible
  verify_first_rollup >/dev/null 2>&1
}

T1=1000; T2=1030

# --- I ----------------------------------------------------------------------
HW0=6 HW1=5; RECS0="$(rec $T1 1)"$'\n'; RECS1=""; RESET_FIRST_ROLLUP_WAIT=10
run_case
if printf '%s\n' "$out" | grep -Eq "first rollup $BPOD: observed_at=[^ ]+ classes=1 asset_count=1 PREDICTED=1 -> MET$" \
   && [ "$RC" = 0 ] && [ "$OF" = 0 ]; then
  pass "I: one record carrying 1 -> MET, rc 0, OVERALL_FAIL=0"
else
  fail "I: (RC=$RC OF=$OF) :: $out"
fi
# N: the record fields
if [ "$FIRST_ROLLUP_COUNT" = 1 ] && [ "$FIRST_ROLLUP_VERDICT" = MET ] && [ -n "$FIRST_ROLLUP_AT" ]; then
  pass "N: first_rollup fields set for the reset record (1, MET)"
else
  fail "N: count=$FIRST_ROLLUP_COUNT verdict=$FIRST_ROLLUP_VERDICT at=$FIRST_ROLLUP_AT"
fi

# --- J ----------------------------------------------------------------------
HW0=6 HW1=7; RECS0="$(rec $T1 1)"$'\n'; RECS1="$(rec $T1 1)"$'\n'"$(rec $T2 5)"$'\n'
run_case
if printf '%s\n' "$out" | grep -Eq "first rollup $BPOD: observed_at=[^ ]+ classes=2 asset_count=2 PREDICTED=1 -> MISS$" \
   && [ "$RC" = 0 ] && [ "$OF" = 0 ]; then
  pass "J: two class records (1+1) counted, later sweep (5) not -> asset_count=2 MISS, exit unaffected"
else
  fail "J: (RC=$RC OF=$OF) :: $out"
fi

# --- K ----------------------------------------------------------------------
HW0=5 HW1=5; RECS0=""; RECS1=""; RESET_FIRST_ROLLUP_WAIT=1
run_case
if printf '%s\n' "$out" | grep -q 'first rollup: not measured in this run (no rollup by T+1s after producers returned' \
   && [ "$RC" = 0 ] && [ "$OF" = 0 ]; then
  pass "K: no advance by the deadline -> not measured, exit unaffected"
else
  fail "K: (RC=$RC OF=$OF) :: $out"
fi
[ "$FIRST_ROLLUP_VERDICT" = "not measured" ] && pass "K: record verdict stays 'not measured'" \
  || fail "K: verdict=$FIRST_ROLLUP_VERDICT"

# --- M ----------------------------------------------------------------------
HW0=6 HW1=5; RECS0="$(rec $T1 0)"$'\n'; RECS1=""; RESET_FIRST_ROLLUP_WAIT=10
run_case
if printf '%s\n' "$out" | grep -Eq "first rollup $BPOD: observed_at=[^ ]+ classes=1 asset_count=0 PREDICTED=1 -> MISS$" \
   && ! printf '%s\n' "$out" | grep -q UNREADABLE && [ "$OF" = 0 ]; then
  pass "M: absent asset_count -> asset_count=0 MISS, not UNREADABLE"
else
  fail "M: (RC=$RC OF=$OF) :: $out"
fi

# --- UNREADABLE: garbage value ------------------------------------------------
HW0=6 HW1=5; RECS0="Zm9v"$'\n'; RECS1=""
run_case
if printf '%s\n' "$out" | grep -Eq "first rollup $BPOD: UNREADABLE \(" && [ "$OF" = 0 ] && [ "$RC" = 0 ]; then
  pass "decode failure -> UNREADABLE, exit unaffected"
else
  fail "UNREADABLE: (RC=$RC OF=$OF) :: $out"
fi

# --- L: quick mode never reaches phase 11 ------------------------------------------
LOG="$(mktemp)"; trap 'rm -f "$LOG"' EXIT
verify_first_rollup()           { echo "11" >> "$LOG"; }
phase2_quiesce() { :; }; phase3_restate() { :; }; phase5_aggregator() { :; }; phase6_stores() { :; }
phase7_electric() { :; }; phase9_restore_producers() { :; }
quick_quiesce_all() { :; }; quick_restate() { :; }; quick_topics() { :; }; quick_stores() { :; }
phase10_subscription_liveness() { echo "10" >> "$LOG"; }
write_exercise_reset_record() { :; }
( QUICK=true; DRY_RUN=false; run_reset_sequence ) >/dev/null 2>&1
if [ ! -s "$LOG" ]; then
  pass "L: quick mode -> phase 11 (and 10) never run"
else
  fail "L: quick ran: $(tr '\n' ' ' < "$LOG")"
fi

echo
if [ "$FAIL" -eq 0 ]; then
  echo "test_reset_first_rollup: ALL PASS"
  exit 0
fi
echo "test_reset_first_rollup: FAILED"
exit 1
