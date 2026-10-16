#!/usr/bin/env bash
# ===========================================================================
# test_reset_heartbeat_topics.sh -- offline proof that verify_topics scores a
# declared heartbeat topic (*-aggregator-sweep-tick) by trim mark + cadence
# bound, and scores every other topic exactly as before. Sources the REAL
# reset-scenario.sh via the RESET_SCENARIO_SOURCE_ONLY seam.
# ===========================================================================
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${SCRIPT:-$HERE/../reset-scenario.sh}"

export NS=openddil RELEASE=openddil RESET_SCENARIO_SOURCE_ONLY=1
set --
# shellcheck source=../reset-scenario.sh
. "$SCRIPT"
set +e

FAIL=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAIL=1; }

# synthetic broker: TOPIC_ROWS is "topic|logstart|hw" lines
TOPIC_ROWS=""
broker_topics() { printf '%s\n' "$TOPIC_ROWS" | cut -d'|' -f1; }
topic_partitions() {
  printf '%s\n' "$TOPIC_ROWS" | awk -F'|' -v t="$2" '$1==t {print "0", $2, $3}'
}

run_case() {  # run_case ROWS MARK_OR_- EPOCH_OFFSET_OR_-  -> sets OUT, OF
  TOPIC_ROWS="$1"
  REDPANDA_PODS=(redpanda-0)
  declare -gA TRIM_MARK=()
  [ "$2" != "-" ] && TRIM_MARK["redpanda-0|region-a-aggregator-sweep-tick|0"]="$2"
  if [ "$3" = "-" ]; then unset AGGREGATOR_RESTORED_EPOCH
  else AGGREGATOR_RESTORED_EPOCH=$(( $(date +%s) - $3 )); fi
  OVERALL_FAIL=0
  OUT="$(verify_topics; echo "OF=$OVERALL_FAIL")"
  OF="${OUT##*OF=}"
}
HB=region-a-aggregator-sweep-tick

run_case "$HB|314|315" 314 40
if [ "$OF" = 0 ] && ! grep -q FAIL <<<"$OUT"; then pass "a: within bound"; else fail "a: within bound"; echo "$OUT"; fi

run_case "$HB|314|320" 314 40
if [ "$OF" = 1 ] && grep -q FAIL <<<"$OUT"; then pass "b: overrun fails"; else fail "b: overrun fails"; echo "$OUT"; fi

run_case "$HB|300|315" 314 40
if [ "$OF" = 1 ] && grep -q FAIL <<<"$OUT"; then pass "c: log_start != mark fails"; else fail "c"; echo "$OUT"; fi

run_case "$HB|314|315" - 40
if [ "$OF" = 1 ] && grep -q UNMEASURED <<<"$OUT"; then pass "d: no mark UNMEASURED"; else fail "d"; echo "$OUT"; fi

run_case "$HB|314|315" 314 -
if [ "$OF" = 1 ] && grep -q FAIL <<<"$OUT"; then pass "e: no epoch fails"; else fail "e"; echo "$OUT"; fi

run_case "synth-ordinary|10|12" - 40
if [ "$OF" = 1 ] && grep -q FAIL <<<"$OUT"; then pass "f: ordinary hw!=log_start fails"; else fail "f"; echo "$OUT"; fi

run_case "synth-ordinary|12|12" - 40
if [ "$OF" = 0 ] && ! grep -q FAIL <<<"$OUT"; then pass "g: ordinary hw==log_start passes"; else fail "g"; echo "$OUT"; fi

# h: malformed declaration halts sourcing, naming the entry
H="$( (RESET_HEARTBEAT_TOPICS="x-*=abc" RESET_SCENARIO_SOURCE_ONLY=1 NS=openddil RELEASE=openddil; set --; . "$SCRIPT") 2>&1; echo "rc=$?")"
if grep -q 'x-\*=abc' <<<"$H" && ! grep -q 'rc=0$' <<<"$H"; then pass "h: malformed entry halts"; else fail "h: malformed entry halts"; echo "$H"; fi

# i: trim_topic_to_hw records marks
maybe_run() { shift; "$@"; }
kubectl() { return 0; }
TOPIC_ROWS="t-trim|5|9
t-same|7|7"
declare -gA TRIM_MARK=()
trim_topic_to_hw redpanda-0 t-trim >/dev/null
trim_topic_to_hw redpanda-0 t-same >/dev/null
if [ "${TRIM_MARK[redpanda-0|t-trim|0]:-}" = 9 ] && [ "${TRIM_MARK[redpanda-0|t-same|0]:-}" = 7 ]; then
  pass "i: trim marks recorded"; else fail "i: trim marks recorded"; declare -p TRIM_MARK; fi

[ "$FAIL" = 0 ] && echo "test_reset_heartbeat_topics: ALL PASS" || { echo "test_reset_heartbeat_topics: FAILED"; exit 1; }
