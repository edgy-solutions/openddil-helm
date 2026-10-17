#!/usr/bin/env bash
# ===========================================================================
# test_reset_first_rollup.sh -- offline proof for phase 9b of reset-scenario.sh
# (verify_first_rollup), against the REAL function and decoder. kubectl, the
# partition reader, pg_query, the clock and sleep are stubbed; the protobuf
# values are built by hand below (field 1 string, field 6 varint, field 7
# nested seconds varint).
#
# The store count is a scripted sequence (one count per poll) served by a
# pg_query stub; the runner clock is a stub that returns 1000 + 2*n on its
# n-th call, so store read n is stamped 1000 + 2n. The hw advances once the
# ADV_AT-th store read has been made. A rollup's observed_at T is picked
# between two reads to say which read is the "same instant".
#
# Cases:
#   I'. store 0,0,3,3, rollup of 3 at T after read 3   -> PREDICTED=3 -> MET, clause 1 HELD.
#   J'. store 0,2,4, rollup of 2 at T between reads 2 and 3 -> PREDICTED=2 (last <= T),
#       after=4 -> MET; the same T with a rollup of 4 -> MISS.
#   K'. no advance, store 0 throughout   -> "consistent with clause 1", exit unaffected.
#   K''. no advance, store reaches 5     -> MISS (store reached 5 ..., no rollup ...).
#   V.  an advance while every store read so far is 0 -> clause 1: VIOLATED.
#   L.  quick mode                        -> phase 9b never runs.
#   M.  asset_count absent on the wire    -> asset_count=0 (not UNREADABLE).
#   S.  store unreadable                  -> UNREADABLE (store: ...).
#   B.  a broker other than region-east   -> "no store to compare", no verdict.
#   N.  the reset record carries the measured first_rollup fields.
# In every case the phase never changes OVERALL_FAIL and returns 0.
# Flips: SCRIPT=<mutated copy> (predict from the first entry after T; MISS
# routed via report).
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

W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT

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
POSTGRES_PODS=("openddil-postgres-region-east-0" "openddil-postgres-hq-0")
STORE_SEQ=()         # one count per poll; the last repeats. "ERR" -> the read fails
ADV_AT=999           # the hw advances once this many store reads have been made
RECS0=""             # base64 lines served for partition 0
: > "$W/polls"; : > "$W/clock"
nreads() { wc -l < "$W/polls" | tr -d ' '; }
sleep() { :; }
_first_rollup_now() { echo x >> "$W/clock"; echo $(( 1000 + 2 * $(wc -l < "$W/clock" | tr -d ' ') )); }
pg_query() {
  local n idx last
  echo x >> "$W/polls"
  n="$(nreads)"; idx=$((n - 1)); last=$(( ${#STORE_SEQ[@]} - 1 ))
  [ "$idx" -gt "$last" ] && idx="$last"
  [ "${STORE_SEQ[$idx]}" = ERR ] && return 1
  echo "${STORE_SEQ[$idx]}"
}
topic_partitions() {
  if [ "$(nreads)" -ge "$ADV_AT" ]; then echo "0 5 6"; else echo "0 5 5"; fi
  echo "1 5 5"
}
kubectl() { printf '%s' "$RECS0"; }

# run_case -> out, RC, OF  (marks are 5 and 5 on the one broker)
run_case() {
  AGG_EMPTY_HW=(); AGG_EMPTY_HW["$BPOD|0"]=5; AGG_EMPTY_HW["$BPOD|1"]=5
  FIRST_ROLLUP_COUNT=""; FIRST_ROLLUP_AT=""; FIRST_ROLLUP_VERDICT="not measured"; FIRST_ROLLUP_BROKER=""
  FIRST_ROLLUP_PREDICTED=""; FIRST_ROLLUP_STORE_AFTER=""; FIRST_ROLLUP_CLAUSE1=""
  OVERALL_FAIL=0; DRY_RUN=false; PHASE9_DONE_AT=""
  : > "$W/polls"; : > "$W/clock"
  out="$(verify_first_rollup 2>&1; echo "RC=$?"; echo "OF=$OVERALL_FAIL")"
  RC="$(printf '%s\n' "$out" | sed -n 's/^RC=//p')"
  OF="$(printf '%s\n' "$out" | sed -n 's/^OF=//p')"
  # run once more in this shell so the globals (record fields) are visible
  : > "$W/polls"; : > "$W/clock"
  verify_first_rollup >/dev/null 2>&1
}
has() { printf '%s\n' "$out" | grep -Eq -- "$1"; }

RESET_FIRST_ROLLUP_WAIT=10
# --- I' ---------------------------------------------------------------------
STORE_SEQ=(0 0 3 3); ADV_AT=4; RECS0="$(rec 1007 3)"$'\n'
run_case
if has "first rollup $BPOD: observed_at=[^ ]+ classes=1 asset_count=3 PREDICTED=3 -> MET$" \
   && has "store before=3@[^ ]+ after=3@[^ ]+$" && has "clause 1: no rollup while store=0: HELD$" \
   && [ "$RC" = 0 ] && [ "$OF" = 0 ]; then
  pass "I': store 0,0,3,3, rollup of 3 -> PREDICTED=3 MET, clause 1 HELD, rc 0, OVERALL_FAIL=0"
else
  fail "I': (RC=$RC OF=$OF) :: $out"
fi
# N: the record fields
if [ "$FIRST_ROLLUP_COUNT" = 3 ] && [ "$FIRST_ROLLUP_VERDICT" = MET ] && [ -n "$FIRST_ROLLUP_AT" ] \
   && [ "$FIRST_ROLLUP_PREDICTED" = 3 ] && [ "$FIRST_ROLLUP_STORE_AFTER" = 3 ] && [ "$FIRST_ROLLUP_CLAUSE1" = HELD ]; then
  pass "N: first_rollup globals set (3, predicted 3, after 3, HELD, MET)"
else
  fail "N: count=$FIRST_ROLLUP_COUNT pred=$FIRST_ROLLUP_PREDICTED after=$FIRST_ROLLUP_STORE_AFTER c1=$FIRST_ROLLUP_CLAUSE1 verdict=$FIRST_ROLLUP_VERDICT"
fi
# N: the one builder turns them into the record JSON
KLOG="$W/kubectl.log"; : > "$KLOG"
(
  kubectl() { echo "$*" >> "$KLOG"; }
  DRY_RUN=false; CLEAR_DECLARATIONS=false; DECLARED_UNMEASURED_USED=()
  write_exercise_reset_record
) >/dev/null 2>&1
if grep -Fq '"first_rollup": {"asset_count": 3, "observed_at": "' "$KLOG" \
   && grep -Fq '"predicted": 3, "store_after": 3, "clause1": "HELD", "verdict": "MET"}' "$KLOG"; then
  pass "N: reset record JSON carries asset_count, observed_at, predicted, store_after, clause1, verdict"
else
  fail "N: record JSON :: $(grep -o '"first_rollup".*' "$KLOG" | head -1)"
fi

# --- J' ---------------------------------------------------------------------
STORE_SEQ=(0 2 4); ADV_AT=3; RECS0="$(rec 1005 2)"$'\n'
run_case
if has "asset_count=2 PREDICTED=2 -> MET$" && has "store before=2@[^ ]+ after=4@[^ ]+$" \
   && [ "$RC" = 0 ] && [ "$OF" = 0 ]; then
  pass "J': T between reads 2 and 3 -> PREDICTED=2 (last entry <= T), after=4 -> MET"
else
  fail "J': (RC=$RC OF=$OF) :: $out"
fi
RECS0="$(rec 1005 4)"$'\n'
run_case
if has "asset_count=4 PREDICTED=2 -> MISS$" && [ "$RC" = 0 ] && [ "$OF" = 0 ]; then
  pass "J': same T with a rollup of 4 -> MISS, exit unaffected"
else
  fail "J' MISS: (RC=$RC OF=$OF) :: $out"
fi

# --- K' ---------------------------------------------------------------------
STORE_SEQ=(0); ADV_AT=999; RECS0=""; RESET_FIRST_ROLLUP_WAIT=6
run_case
if has "first rollup: none in 6s and store=0 throughout: consistent with clause 1 \(feed resumes with the exercise restart\)$" \
   && [ "$RC" = 0 ] && [ "$OF" = 0 ]; then
  pass "K': no advance, store 0 throughout -> consistent with clause 1, exit unaffected"
else
  fail "K': (RC=$RC OF=$OF) :: $out"
fi
[ "$FIRST_ROLLUP_VERDICT" = "not measured" ] && pass "K': record verdict stays 'not measured'" \
  || fail "K': verdict=$FIRST_ROLLUP_VERDICT"

# --- K'' --------------------------------------------------------------------
STORE_SEQ=(0 0 5); ADV_AT=999
run_case
if has "first rollup: MISS \(store reached 5 at [^ ]+, no rollup by T\+6s\)$" && [ "$RC" = 0 ] && [ "$OF" = 0 ]; then
  pass "K'': no advance, store reaches 5 -> MISS (store reached 5 ...), exit unaffected"
else
  fail "K'': (RC=$RC OF=$OF) :: $out"
fi

# --- V ----------------------------------------------------------------------
RESET_FIRST_ROLLUP_WAIT=10
STORE_SEQ=(0 0); ADV_AT=2; RECS0="$(rec 1003 1)"$'\n'
run_case
if has "clause 1: VIOLATED \(rollup at [^ ]+ while store=0\)$" && [ "$FIRST_ROLLUP_CLAUSE1" = VIOLATED ] \
   && [ "$RC" = 0 ] && [ "$OF" = 0 ]; then
  pass "V: advance while every store read is 0 -> clause 1: VIOLATED, exit unaffected"
else
  fail "V: (RC=$RC OF=$OF) :: $out"
fi

# --- M: absent asset_count ------------------------------------------------------
STORE_SEQ=(2 2 2); ADV_AT=3; RECS0="$(rec 1005 0)"$'\n'
run_case
if has "classes=1 asset_count=0 PREDICTED=2 -> MISS$" && ! printf '%s\n' "$out" | grep -q UNREADABLE && [ "$OF" = 0 ]; then
  pass "M: absent asset_count -> asset_count=0, not UNREADABLE"
else
  fail "M: (RC=$RC OF=$OF) :: $out"
fi

# --- UNREADABLE: garbage value ------------------------------------------------
STORE_SEQ=(2); ADV_AT=1; RECS0="Zm9v"$'\n'
run_case
if has "first rollup $BPOD: UNREADABLE \(" && [ "$OF" = 0 ] && [ "$RC" = 0 ]; then
  pass "decode failure -> UNREADABLE, exit unaffected"
else
  fail "UNREADABLE: (RC=$RC OF=$OF) :: $out"
fi

# --- S: store unreadable ----------------------------------------------------------
STORE_SEQ=(ERR); ADV_AT=2; RECS0="$(rec 1003 1)"$'\n'
run_case
if has "UNREADABLE \(store: " && [ "$OF" = 0 ] && [ "$RC" = 0 ]; then
  pass "S: store read fails -> UNREADABLE (store: ...), exit unaffected"
else
  fail "S: (RC=$RC OF=$OF) :: $out"
fi

# --- B: a broker with no store ------------------------------------------------------
BPOD_SAVE="$BPOD"; BPOD="openddil-redpanda-hq-0"
STORE_SEQ=(2); ADV_AT=2; RECS0="$(rec 1003 1)"$'\n'
run_case
if has "first rollup $BPOD: observed_at=[^ ]+ classes=1 asset_count=1 \(no store to compare\)$" \
   && ! has "PREDICTED=" && ! has "MET|MISS" && [ "$OF" = 0 ]; then
  pass "B: non-region-east broker -> count printed, no store to compare, no verdict"
else
  fail "B: (RC=$RC OF=$OF) :: $out"
fi
BPOD="$BPOD_SAVE"

# --- L: quick mode never reaches phase 9b -----------------------------------------
LOG="$(mktemp)"; trap 'rm -rf "$W"; rm -f "$LOG"' EXIT
verify_first_rollup()           { echo "9b" >> "$LOG"; }
phase2_quiesce() { :; }; phase3_restate() { :; }; phase5_aggregator() { :; }; phase6_stores() { :; }
phase7_electric() { :; }; phase9_restore_producers() { :; }
quick_quiesce_all() { :; }; quick_restate() { :; }; quick_topics() { :; }; quick_stores() { :; }
phase10_subscription_liveness() { echo "10" >> "$LOG"; }
write_exercise_reset_record() { :; }
( QUICK=true; DRY_RUN=false; run_reset_sequence ) >/dev/null 2>&1
if [ ! -s "$LOG" ]; then
  pass "L: quick mode -> phase 9b (and 10) never run"
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
